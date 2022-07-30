import strformat,
       sugar,
       strutils,
       tables,
       nimpy,
       std/os,
       times,
       std/monotimes,
       locks,
       karax/vdom,
       strtabs,
       nre,
       options,
       fusion/matching,
       uri,
       lrucache,
       zippy,
       std/hashes,
       chronos,
       scorper,
       scorper/http/httpcore,
       std/cpuinfo,
       json,
       faststreams/inputs,
       locktplasync,
       lrucache

{.experimental: "caseStmtMacros".}

import
  pyutils,
  quirks,
  cfg,
  types,
  server_types,
  server_tasks,
  topics,
  utils,
  html,
  publish,
  translate,
  translate_db,
  rss,
  amp,
  ads,
  opg,
  ldj,
  imageflow_server,
  cache,
  search,
  sitemap,
  articles,
  stats

asyncLockedStore(LruCache)
asyncLockedStore(Table)

type
  ReqContext = object of RootObj
    rq: Table[ReqId, Request]
    url: uri.Uri
    mime: string
    file: string
    key: int64
    headers: HttpHeaders
    norm_capts: UriCaptures
    respHeaders: HttpHeaders
    respBody: string
    respCode: HttpCode
    cached: bool # done processing
  ReqId = MonoTime # using time as request id means that the request cache should be thread local

converter reqPtr(rc: ref ReqContext): uint64 = cast[uint64](rc)

proc getReqId(): ReqId = getMonoTime()

var
  threadInitialized {.threadvar.}: bool
  reqCtxCache {.threadvar.}: LockLruCache[string, ref ReqContext]
  urlCache {.threadvar.}: LockLruCache[string, ref Uri]
  emptyHttpValues {.threadvar.}: ptr HttpHeaderValues
  emptyHttpHeaders {.threadvar.}: ptr HttpHeaders
  reqCompleteEQ: ptr AsyncEventQueue[ref ReqContext]
  reqEventQK: ptr EventQueueKey

proc initThreadBase*() {.gcsafe.} =
  initPy()
  initTypes()
  initLogging()

proc initThread*() {.gcsafe.} =
  if threadInitialized:
    return
  initThreadBase()
  initHtml()
  addLocks()
  initLDJ()
  initFeed()
  startImgFlow()
  initSonic()
  initMimes()
  try:
    initAmp()
  except:
    qdebug "server: failed to initAmp"
  initOpg()
  try:
    translate.initThread()
  except:
    qdebug "failed to init translate"

  reqCtxCache = initLockLruCache[string, ref ReqContext](1000)
  urlCache = initLockLruCache[string, ref Uri](1000)
  reqCompleteEQ = create(AsyncEventQueue[ref ReqContext])
  reqCompleteEQ[] = newAsyncEventQueue[ref ReqContext]()
  reqEventQK = create(EventQueueKey)
  reqEventQK[] = reqCompleteEQ[].register()
  emptyHttpValues = create(HttpHeaderValues)
  emptyHttpHeaders = create(HttpHeaders)
  emptyHttpValues[] = @[""].HttpHeaderValues
  emptyHttpHeaders[] = newHttpHeaders()
  waitFor syncTopics()

  threadInitialized = true


template setEncoding() {.dirty.} =
  let rqHeaders = reqCtx.rq[rqid].headers
  assert not rqHeaders.isnil
  debug "reply: declaring accept"
  let accept = $(rqHeaders.getOrDefault("Accept-Encoding", deepcopy(
      emptyHttpValues[])))
  if ("*" in accept) or ("gzip" in accept):
    debug "reply: encoding gzip"
    reqCtx.respHeaders[$hencoding] = "gzip"
    if reqCtx.respBody != "":
      debug "reply: compressing body (gzip)"
      reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfGzip)
  elif "deflate" in accept:
    debug "reply: encoding deflate"
    reqCtx.respHeaders[$hencoding] = "deflate"
    if reqCtx.respBody != "":
      reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfDeflate)
      debug "reply: compressing body (deflate)"

proc doReply(reqCtx: ref ReqContext, body: string, rqid: ReqId, scode = Http200,
    headers: HttpHeaders = nil) {.async.} =
  if headers.isnil:
    sdebug "reply: new headers"
    reqCtx.respHeaders = newHttpHeaders()
  else:
    reqCtx.respHeaders = headers
  sdebug "reply: setting body"
  reqCtx.respBody = if likely(body != ""): body
                    else:
                      sdebug "reply: body is empty!"
                      ""
  if reqCtx.mime == "":
    sdebug "reply: mimepath"
    reqCtx.mime = mimePath(reqCtx.file)
  sdebug "reply: setting mime"
  reqCtx.respHeaders[$hcontent] = reqCtx.mime
  try:
    sdebug "reply: encoding type header"
    if sre("^(?:text)|(?:image)|(?:application)/") in reqCtx.mime:
      setEncoding
    debug "reply: headers -- {reqCtx.respHeaders}"
    reqCtx.respHeaders[$hetag] = '"' & $reqCtx.key & '"'
  except:
    swarn "reply: troubles serving page {reqCtx.file}"
    sdebug "reply: sending: {len(reqCtx.respBody)} to {reqCtx.url}"
  try:
    reqCtx.respCode = scode
    # assert len(respbody) > 0, "reply: Can't send empty body!"
    debug "reply: sending response {reqCtx.key}"
    await reqCtx.rq[rqid].resp(content = reqCtx.respBody,
        headers = reqCtx.respHeaders, code = reqCtx.respCode)
    sdebug "reply: sent: {len(reqCtx.respBody)}"
  except Exception as e:
    sdebug "reply: {getCurrentExceptionMsg()}, {getStackTrace()}"

proc doReply(reqCtx: ref ReqContext, rqid: ReqId) {.async.} =
  await reqCtx.rq[rqid].resp(content = reqCtx.respBody,
      headers = reqCtx.respHeaders, code = reqCtx.respCode)

{.push dirty.}
# NOTE: `scorper` crashes when sending empty (`""`) responses, so send code
template handle301*(loc: string = $WEBSITE_URL) =
  let headers = @[("Location", loc)].newHttpHeaders
  debug "redirect, trace:\n {getStackTrace()}"
  await reqCtx.doReply($Http301, rqid, scode = Http301, headers = headers)

template handle404*(loc = $WEBSITE_URL) =
  await reqCtx.doReply($Http404, rqid, scode = Http404)

template handle501*(loc = $WEBSITE_URL) =
  await reqCtx.doReply($Http501, rqid, scode = Http501)

template handleHomePage(relpath: string, capts: UriCaptures,
    ctx: Request) =
  const homePath = hash(SITE_PATH / "index.html")
  page = pageCache[].lcheckOrPut(reqCtx.key):
    # in case of translations, we to generate the base page first
    # which we cache too (`setPage only caches the page that should be served)
    let (tocache, toserv) = await buildHomePage(capts.lang, capts.amp)
    pageCache[homePath] = tocache.asHtml(minify_css = (capts.amp == ""))
    toserv.asHtml(minify_css = (capts.amp == ""))
  await reqCtx.doReply(page, rqid)

template handleAsset() =

  var data: seq[byte]
  when not defined(noAssetsCaching):
    reqCtx.mime = mimePath(reqCtx.file)
    try:
      page = pageCache[].get(reqCtx.key)
    except KeyError:
      try:
        page = await readFileAsync(reqCtx.file)
        if page != "":
          pageCache[reqCtx.key] = page
      except:
        handle404()
  else:
    debug "ASSETS CACHING DISABLED"
    try:
      reqCtx.mime = mimePath(reqCtx.file)
      page = await readFileAsync(reqCtx.file)
    except:
      handle404()
  await reqCtx.doReply(page, rqid, )

template dispatchImg() =
  var mime: string
  var imgPath = reqCtx.url.path & "?" & reqCtx.url.query
  # fix for image handling, since images use queries, therefore paths are not unique
  reqCtx.file = imgPath
  imgPath.removePrefix("/i")
  reqCtx.key = hash(reqCtx.file)
  try:
    (mime, page) = pageCache[].get(reqCtx.key).split(";", maxsplit = 1)
    debug "img: fetched from cache {reqCtx.key} {imgPath}"
  except KeyError, AssertionDefect:
    debug "img: not found handling image, {imgPath}"
    try: (page, mime) = await handleImg(imgPath)
    except: debug "img: could not handle image {imgPath} \n {getCurrentExceptionMsg()}"
    if page != "":
      # append the mimetype before the img data
      pageCache[][reqCtx.key] = mime & ";" & page
      debug "img: saved to cache {reqCtx.key} : {reqCtx.url}"
  if page != "":
    reqCtx.mime = mime
    await reqCtx.doReply(page, rqid, )
  else:
    handle404()

template handleTopic(capts: auto, ctx: Request) =
  debug "topic: looking for {capts.topic}"
  if capts.topic in topicsCache:
    page = pageCache[].lcheckOrPut(reqCtx.key):
      let topic = capts.topic
      let pagenum = if capts.page == "": $(await topic.lastPageNum()) else: capts.page
      debug "topic: page: ", capts.page
      topicPage(topic, pagenum, false)
      let pageReqKey = (capts.topic / capts.page).fp.hash
      pageCache[pageReqKey] = pagetree.asHtml
      (await processPage(capts.lang, capts.amp, pagetree)).asHtml(minify_css = (
          capts.amp == ""))
    updateHits(capts)
    await reqCtx.doReply(page, rqid, )
  elif capts.topic in customPages:
    debug "topic: looking for custom page"
    page = pageCache[].lcheckOrPut(reqCtx.key):
      await pageFromTemplate(capts.topic, capts.lang, capts.amp)
    await reqCtx.doReply(page, rqid, )
  else:
    var filename = capts.topic.extractFilename()
    debug "topic: looking for assets {filename:.120}"
    if filename in assetsFiles[]:
      page = pageCache[].lcheckOrPut(filename):
        await readFileAsync(DATA_ASSETS_PATH / filename)
      await reqCtx.doReply(page, rqid, )
    else:
      debug "topic: asset not found at {DATA_ASSETS_PATH / filename:.120}"
      handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleArticle(capts: auto, ctx: Request) =
  ##
  debug "article: fetching article"
  let tg = topicsCache.get(capts.topic, emptyTopic)
  if tg.topdir != -1:
    page = pageCache[].lcheckOrPut(reqCtx.key):
      debug "article: generating article"
      await articleHtml(capts)
    if page != "":
      updateHits(capts)
      await reqCtx.doReply(page, rqid, )
    else:
      debug "article: redirecting to topic because page is empty"
      handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
  else:
    handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleSearch(relpath: string, ctx: Request) =
  # extract the referer to get the correct language
  assert not ctx.headers.isnil
  let
    refuri = parseUri($(ctx.headers.getOrDefault("referer", emptyHttpValues[])))
    refcapts = refuri.path.uriTuple
  if capts.lang == "" and refcapts.lang != "":
    handle301($(WEBSITE_URL / refcapts.lang / join(capts, n = 1)))
  else:
    page = searchCache.lcheckOrPut(reqCtx.key):
      # there is no specialized capture for the query
      var searchq = reqCtx.url.query.getParam("q")
      let lang = something(capts.lang, refcapts.lang)
      # this is for js-less form redirection
      if searchq == "" and ($reqCtx.url.query == ""):
        searchq = capts.art.strip()
      (await buildSearchPage(if capts.topic != "s": capts.topic else: "",
          searchq, lang)).asHtml
    reqCtx.mime = mimePath("index.html")
    await reqCtx.doReply(page, rqid, )

template handleSuggest(relpath: string, ctx: Request) =
  # there is no specialized capture for the query
  let
    prefix = reqCtx.url.query.getParam("p")
    searchq = something(reqCtx.url.query.getParam("q"), capts.art)
  page = await buildSuggestList(capts.topic, searchq, prefix)
  await reqCtx.doReply(page, rqid, )

template handleFeed() =
  page = await fetchFeedString(capts.topic)
  await reqCtx.doReply(page, rqid, )

template handleSiteFeed() =
  page = await fetchFeedString()
  await reqCtx.doReply(page, rqid, )

template handleTopicSitemap() =
  page = await fetchSiteMap(capts.topic)
  await reqCtx.doReply(page, rqid, )

template handleSitemap() =
  page = await fetchSiteMap("")
  await reqCtx.doReply(page, rqid, )

template handleRobots() =
  page = pageCache[].lcheckOrPut(reqCtx.key):
    buildRobots()
  await reqCtx.doReply(page, rqid, )

template handleCacheClear() =
  case nocache:
    of '0':
      const notTopics = ["assets", "i", "robots.txt", "feed.xml", "sitemap.xml",
          "s", "g"].toHashSet
      reqCtx.cached = false
      reqCtx.norm_capts = uriTuple(reqCtx.url.path)
      {.cast(gcsafe).}:
        try:
          if reqCtx.norm_capts.art != "" and
            not (reqCtx.norm_capts.topic in notTopics) and
            not (reqCtx.norm_capts.page in notTopics):
            debug "cache: deleting article cache {reqCtx.norm_capts.art:.40}"
            await deleteArt(reqCtx.norm_capts, cacheOnly = true)
          elif reqCtx.norm_capts.topic == "i":
            let k = hash(reqCtx.url.path & reqCtx.url.query)
            pageCache[].del(k)
          elif reqCtx.norm_capts.topic in notTopics:
            debug "cache: deleting key {reqCtx.key}"
            pageCache[].del(reqCtx.key)
          else:
            debug "cache: deleting page {reqCtx.url.path}"
            deletePage(reqCtx.url.path)
        except:
          warn "cache: deletion failed for {reqCtx.norm_capts:.120}"
    of '1':
      {.cast(gcsafe).}:
        pageCache[].clear()
      warn "cache: cleared all pages"
    else:
      discard

template abort() =
  if unlikely(reqCtx.cached):
    reqCtxCache.del(relpath)
  try:
    handle301()
    debug "Router failed, Exception: \n {getCurrentExceptionMsg()}, \n Stacktrace: \n {getStacktrace()}"
  except:
    handle501()

{.pop dirty.}

proc handleGet(ctx: Request): Future[bool] {.gcsafe, async.} =
  initThread()
  # doassert ctx.parseRequestLine
  var
    relpath = ctx.path
    page: string
    nocache: char
    generated: bool
  relpath.removeSuffix('/')
  debug "handling: {relpath:.120}"

  # parse url and check cache key
  var url = urlCache.lcheckOrPut(relpath):
    var u: ref Uri; new(u)
    parseUri(relpath, u[]); u
  let cache_param = url.query.getParam("cache")
  if cache_param.len > 0:
    nocache = cache_param[0]
  if nocache != '\0':
    url.query = url.query.replace(sre "&?cache=[0-9]&?", "")

  # generate request super context
  let reqCacheKey = $(url.path & url.query)
  let reqCtx = reqCtxCache.lcheckOrPut(reqCacheKey):
    let reqCtx = new(ReqContext)
    generated = true
    reqCtx.url = url[]
    reqCtx.file = reqCtx.url.path.fp
    reqCtx.key = hash(reqCtx.file)
    reqCtx
  # don't replicate works on unfinished requests
  if not generated and not reqCtx.cached:
    while true:
      let events = await reqCompleteEQ[].waitEvents(reqEventQK[])
      for e in events:
        if e == reqCtx:
          break
  let rqid = getReqId()
  reqCtx.rq[rqid] = ctx
  if nocache != '\0':
    handleCacheClear()
  if reqCtx.cached:
    try:
      logall "cache: serving nocache reply, {reqCtx.key} addr: {cast[uint](reqCtx)}"
      await reqCtx.doReply(rqid, )
    except:
      debug "cache: aborting {getCurrentExceptionMsg()}"
      abort()
    return true
  try:
    let capts = uriTuple(reqCtx.url.path)
    case capts:
      of (topic: ""):
        info "router: serving homepage rel: {reqCtx.url.path:.20}, fp: {reqCtx.file:.20}, {reqCtx.key}"
        handleHomePage(reqCtx.url.path, capts, ctx)
      of (topic: "assets"):
        debug "router: serving assets {relpath:.20}"
        handleAsset()
      of (topic: "i"):
        info "router: serving image {relpath:.80}"
        dispatchImg()
      of (topic: "robots.txt"):
        debug "router: serving robots"
        handleRobots()
      of (topic: "feed.xml"):
        info "router: serving site feed"
        handleSiteFeed()
      of (topic: "sitemap.xml"):
        info "router: serving sitemap"
        handleSitemap()
      of (topic: "s"):
        info "router: serving search {relpath:.20}"
        handleSearch(relpath, ctx)
      of (topic: "g"):
        info "router: serving suggestion {relpath:.20}"
        handleSuggest(relpath, ctx)
      of (page: "s"):
        info "router: serving search {relpath:.20}"
        handleSearch(relpath, ctx)
      of (page: "g"):
        info "router: serving suggestion {relpath:.20}"
        handleSuggest(relpath, ctx)
      of (page: "feed.xml"):
        info "router: serving feed for topic {capts.topic:.20}"
        handleFeed()
      of (page: "sitemap.xml"):
        info "router: serving sitemap for topic {capts.topic:.20}"
        handleTopicSitemap()
      of (art: ""):
        info "router: serving topic {relpath:.20}, {reqCtx.key}"
        # topic page
        handleTopic(capts, ctx)
      else:
        # Avoid other potential bad urls
        if relpath.len > 0:
          info "router: serving article {relpath:.20}, {capts:.40}"
          # article page
          handleArticle(capts, ctx)
        else:
          handle301()
        discard
  except: abort()
  finally:
    reqCtx.cached = true
    reqCtx.rq.del(rqid)
    reqCompleteEQ[].emit(reqCtx)
    debug "router: caching req {cast[uint](reqCtx)}"
    # reset(reqCtx.rq)

proc callback(ctx: Request) {.async.} =
  discard await handleGet(ctx)

template wrapInit(code: untyped): proc() =
  proc task(): void =
    initThread()
    code
  task

when declared(Taskpool):
  var tp = Taskpool.new(num_threads = 3)
  template initSpawn(code: untyped, doinit: static[bool] = true) =
    proc mytask(): bool {.closure, gensym, nimcall.} =
      initThread()
      `code`
      true
    discard tp.spawn mytask()

proc startServer*(doclear = false, port = 0, loglevel = "info") =

  let serverPort = if port == 0:
                         os.getEnv("SITE_PORT", "5050").parseInt
                     else: port
  # main Thread
  initThread()

  initCache()
  initStats()
  readAdsConfig()

  # Publishes new articles for one topic every x seconds
  var jobs: seq[Future[void]]
  jobs.add pubTask()

  # cleanup task for deleting low traffic articles
  jobs.add cleanupTask()

  runAdsWatcher()
  runAssetsWatcher()

  # Configure and start server
  # scorper
  let address = "0.0.0.0:" & $serverPort
  while true:
    try:
      waitFor serve(address, callback)
    except:
      warn "server: {getCurrentExceptionMsg()} \n restarting server..."
  # httpbeast
  # var settings = initSettings(port = Port(serverPort), bindAddr = "0.0.0.0")
  # run(callback, settings = settings)

when isMainModule:
  # initThread()
  # let topic = "vps"
  # let page = buildHomePage("en", "")
  # page.writeHtml(SITE_PATH / "index.html")
  # initSonic()
  # let argt = getLastArticles(topic)
  # echo buildRelated(argt[0])
  pageCache[].clear()
  startServer()
