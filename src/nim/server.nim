import strformat,
       sugar,
       fusion/matching,
       strutils,
       tables,
       nimpy,
       std/os,
       times,
       std/monotimes,
       locks,
       karax/vdom,
       strtabs,
       options,
       uri,
       lrucache,
       zip/zlib,
       std/hashes,
       chronos,
       scorper,
       scorper/http/[httpcore, httpcommonheaders],
       std/cpuinfo,
       json,
       locktplasync

{.experimental: "caseStmtMacros".}

import
  pyutils,
  pyhttp,
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
  pwa,
  ads,
  opg,
  ldj,
  imageflow_server,
  cache,
  search,
  sitemap,
  articles,
  stats,
  lsh

from nativehttp import initHttp

# lockedStore(LruCache)
# lockedStore(Table)

type
  ShString {.shallow.} = string
  ReqContext = object of RootObj
    rq: Table[ReqId, Request]
    url: uri.Uri
    mime: string
    file: string
    key: int64
    headers: HttpHeaders
    norm_capts: UriCaptures
    respHeaders: HttpHeaders
    respBody: ShString
    respCode: HttpCode
    lock: AsyncLock # this is acquired while the rq is being processed
    cached: bool    # done processing
  ReqId = MonoTime # using time as request id means that the request cache should be thread local

converter reqPtr(rc: ref ReqContext): uint64 = cast[uint64](rc)

proc getReqId(): ReqId = getMonoTime()

var
  threadInitialized {.threadvar.}: bool
  reqCtxCache {.threadvar.}: LockLruCache[string, ref ReqContext]
  urlCache {.threadvar.}: LockLruCache[string, ref Uri]
  reqCompleteEQ: ptr AsyncEventQueue[ref ReqContext]
  reqEventQK: ptr EventQueueKey

proc initThreadBase() {.gcsafe.} =
  initPy()
  initTypes()
  initLogging()

proc initThreadImpl() {.gcsafe.} =
  if threadInitialized:
    return
  initThreadBase()
  initSonic() # Must be on top
  initHttp()
  initPyHttp()
  initHtml()
  initLDJ()
  initFeed()
  startImgFlow()
  startLsh()
  initMimes()

  initAmp()
  initOpg()
  initTranslate()

  reqCtxCache = initLockLruCache[string, ref ReqContext](32)
  urlCache = initLockLruCache[string, ref Uri](32)
  reqCompleteEQ = create(AsyncEventQueue[ref ReqContext])
  reqCompleteEQ[] = newAsyncEventQueue[ref ReqContext]()
  reqEventQK = create(EventQueueKey)
  reqEventQK[] = reqCompleteEQ[].register()
  waitFor syncTopics()
  loadAssets()
  readAdsConfig()

  threadInitialized = true

proc initThread*() =
  try:
    initThreadImpl()
  except Exception as e:
    warn "Failed to init thread! {e[]}"
    quit!()

template setEncoding() {.dirty.} =
  let rqHeaders = reqCtx.rq[rqid].headers
  assert not rqHeaders.isnil
  debug "reply: declaring accept"
  let accept = $rqHeaders.AcceptEncoding()
  if ("*" in accept) or ("gzip" in accept):
    debug "reply: encoding gzip"
    reqCtx.respHeaders.ContentEncoding("gzip")
    if reqCtx.respBody != "":
      debug "reply: compressing body (gzip)"
      let comp = reqCtx.respBody.compress(stream = GZIP_STREAM)
      reqCtx.respBody = comp
  elif "deflate" in accept:
    debug "reply: encoding deflate"
    reqCtx.respHeaders.ContentEncoding("deflate")
    if reqCtx.respBody != "":
      let comp = reqCtx.respBody.compress(stream = RAW_DEFLATE)
      reqCtx.respBody = comp
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
  reqCtx.respHeaders.ContentType(reqCtx.mime)
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
    sdebug "reply: {e[]}"

proc doReply(reqCtx: ref ReqContext, rqid: ReqId) {.async.} =
  await reqCtx.rq[rqid].resp(content = reqCtx.respBody,
      headers = reqCtx.respHeaders, code = reqCtx.respCode)

{.push dirty.}
# NOTE: `scorper` crashes when sending empty (`""`) responses, so send code
template handle301*(loc: string = $WEBSITE_URL) =
  let headers = newHttpHeaders()
  headers[$hloc] = loc
  block:
    let e = getCurrentException()
    if not e.isnil:
      debug "redirect: start..\n {e[]}\nredirect: ..end."
    await reqCtx.doReply($Http301, rqid, scode = Http301, headers = headers)

template handle404*(loc = $WEBSITE_URL) =
  await reqCtx.doReply($Http404, rqid, scode = Http404)

template handle502*(loc = $WEBSITE_URL) =
  await reqCtx.doReply($Http502, rqid, scode = Http502)

template handleHomePage(relpath: string, capts: UriCaptures,
    ctx: Request) =
  const homePath = hash(SITE_PATH / "index.html")
  page = pageCache[].lcheckOrPut(reqCtx.key):
    # in case of translations, we to generate the base page first
    # which we cache too (`setPage only caches the page that should be served)
    let (tocache, toserv) = await buildHomePage(capts.lang, capts.amp)
    checkTrue not tocache.isnil and not toserv.isnil, "homepage: page generation failed."
    let hpage = tocache.asHtml(minify_css = (capts.amp == ""))
    checkTrue hpage.len > 0, "homepage: minification 1 failed"
    pageCache[homePath] = hpage
    let ppage = toserv.asHtml(minify_css = (capts.amp == ""))
    checkTrue ppage.len > 0, "homepage: minification 2 failed.."
    ppage
  await reqCtx.doReply(page, rqid)

template handleAsset() =

  var data: seq[byte]
  when not defined(noAssetsCaching):
    reqCtx.mime = mimePath(reqCtx.file)
    try:
      page = pageCache[].get(reqCtx.key)
      await reqCtx.doReply(page, rqid, )
    except KeyError:
      try:
        page = await readFileAsync(reqCtx.file)
        if page != "":
          pageCache[reqCtx.key] = page
          await reqCtx.doReply(page, rqid, )
        else:
          handle404()
      except:
        handle404()
  else:
    debug "ASSETS CACHING DISABLED"
    try:
      reqCtx.mime = mimePath(reqCtx.file)
      page = await readFileAsync(reqCtx.file)
      await reqCtx.doReply(page, rqid, )
    except:
      handle404()

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
    except:
      let e = getCurrentException()[]
      debug "img: could not handle image {imgPath} \n {e}"
    if page != "":
      # append the mimetype before the img data
      pageCache[][reqCtx.key] = mime & ";" & page
      debug "img: saved to cache {reqCtx.key} : {reqCtx.url}"
  if page != "":
    reqCtx.mime = mime
    let headers = newHttpHeaders()
    headers.CacheControl("2678400s")
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
      checkNil pagetree, "topic: pagetree couldn't be generated."
      let pageReqKey = (capts.topic / capts.page).fp.hash
      var ppage = pagetree.asHtml
      checkTrue ppage.len > 0, "topic: page gen 1 failed."
      pageCache[pageReqKey] = ppage
      ppage = ""
      checkNil(pagetree):
        let processed = await processPage(capts.lang, capts.amp, pagetree)
        checkNil(processed):
          ppage = processed.asHtml(minify_css = (capts.amp == ""))
      checkTrue ppage.len > 0, "topic: page gen 2 failed."
      ppage
    updateHits(capts)
    await reqCtx.doReply(page, rqid, )
  elif capts.topic in customPages:
    debug "topic: looking for custom page"
    page = pageCache[].lcheckOrPut(reqCtx.key):
      let ppage = await pageFromTemplate(capts.topic, capts.lang, capts.amp)
      checkTrue ppage.len > 0, "topic custom page gen failed."
      ppage
    await reqCtx.doReply(page, rqid, )
  else:
    var filename = capts.topic.extractFilename()
    debug "topic: looking for assets {filename:.120}"
    if filename in assetsFiles[]:
      page = pageCache[].lcheckOrPut(filename):
        # allow to cache this unconditionally of the file existing or not
        await readFileAsync(DATA_ASSETS_PATH / filename)
      await reqCtx.doReply(page, rqid, )
    else:
      debug "topic: asset not found at {DATA_ASSETS_PATH / filename:.120}"
      handle404()

template handleArticle(capts: auto, ctx: Request) =
  ##
  debug "article: fetching article"
  let tg = topicsCache.get(capts.topic, emptyTopic)
  assert not tg.group.isnil
  if tg.topdir != -1:
    try:
      page = pageCache[].lcheckOrPut(reqCtx.key):
        debug "article: generating article"
        let ppage = await articleHtml(capts)
        checkTrue ppage.len > 0, "article: page gen failed."
        ppage
      updateHits(capts)
      await reqCtx.doReply(page, rqid, )
    except ValueError:
      debug "article: redirecting to topic because page is empty"
      handle502()
      # handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
  else:
    handle404()
    # handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleSearch(relpath: string, ctx: Request) =
  # extract the referer to get the correct language
  assert not ctx.headers.isnil
  let
    refuri = parseUri(ctx.headers.Referer())
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
      let ppage = (await buildSearchPage(if capts.topic !=
          "s": capts.topic else: "", searchq, lang)).asHtml
      checkTrue ppage.len > 0, "search: page gen failed."
      ppage
    reqCtx.mime = mimePath("index.html")
    await reqCtx.doReply(page, rqid, )

template handleSuggest(relpath: string, ctx: Request) =
  # there is no specialized capture for the query
  let
    prefix = reqCtx.url.query.getParam("p")
    searchq = something(reqCtx.url.query.getParam("q"), capts.art)
  page = await buildSuggestList(capts.topic, searchq, prefix)
  await reqCtx.doReply(page, rqid, )

template handlePwa() =
  page = pageCache[].lcheckOrPut(reqCtx.key):
    let ppage = siteManifest()
    checkTrue ppage.len > 0, "pwa: page gen failed."
    ppage
  await reqCtx.doReply(page, rqid, )

type feedKind = enum fSite, fTopic
template handleFeed(kind) =
  page = case kind:
    of fSite: await fetchFeedString()
    of fTopic: await fetchFeedString(capts.topic)
  await reqCtx.doReply(page, rqid, )

type smKind = enum smSite, smTopic, smPage, smPageIdx
template handleSiteMap(kind) =
  page = case kind:
    of smSite: await fetchSiteMap()
    of smTopic: await fetchSiteMap(capts.topic)
    of smPage: await fetchSiteMap(capts.topic, capts.page)
    of smPageIdx: await fetchSiteMap(capts.topic, on)
  await reqCtx.doReply(page, rqid)

template handleRobots() =
  page = pageCache[].lcheckOrPut(reqCtx.key):
    let ppage = buildRobots()
    checkTrue ppage.len > 0, "robots: page gen failed."
    ppage
  await reqCtx.doReply(page, rqid, )

template handleCacheClear() =
  case nocache:
    of '0':
      const notTopics = ["assets", "i", "robots.txt", "feed.xml", "index.xml", "sitemap.xml",
          "s", "g"].toHashSet
      reqCtx.cached = false
      reqCtx.norm_capts = uriTuple(reqCtx.url.path)
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
      pageCache[].clear()
      reqCtxCache.clear() # FIXME: should account for running requests...
      warn "cache: cleared all pages"
    else:
      discard

template abort() =
  if unlikely(reqCtx.cached):
    reqCtxCache.del(relpath)

  let e = getCurrentException()[]
  sdebug "Router failed, Exception: \n {e}"
  handle502()

{.pop dirty.}

proc handleGet(ctx: Request): Future[void] {.gcsafe, async.} =
  initThread()
  # doassert ctx.parseRequestLine
  var
    relpath = ctx.path
    page: string
    nocache: char
  relpath.removeSuffix('/')
  debug "handling: {relpath:.120}"

  # parse url and check cache key
  var url = urlCache.lcheckOrPut(relpath):
    let u = new(Uri)
    parseUri(relpath, u[]); u
  let cacheParam = url.query.getParam("cache")
  if cacheParam.len > 0:
    nocache = cacheParam[0]
  if nocache != '\0':
    url.query = url.query.replace(sre "&?cache=[0-9]&?", "")

  # generate request super context
  let acceptEncodingStr = cast[seq[string]](ctx.headers.AcceptEncoding()).join()
  let reqCacheKey = $(url.path & url.query & acceptEncodingStr)
  let reqCtx = reqCtxCache.lcheckOrPut(reqCacheKey):
    let reqCtx {.gensym.} = new(ReqContext)
    reqCtx.lock = newAsyncLock()
    reqCtx.url = url[]
    reqCtx.file = reqCtx.url.path.fp
    reqCtx.key = hash(reqCtx.file)
    reqCtx
  # don't replicate works on unfinished requests
  if not reqCtx.cached:
    await reqCtx.lock.acquire
  let rqid = getReqId()
  reqCtx.rq[rqid] = ctx
  if nocache != '\0':
    handleCacheClear()
  if reqCtx.cached:
    try:
      logall "cache: serving nocache reply, {reqCtx.key} addr: {cast[uint](reqCtx)}"
      await reqCtx.doReply(rqid, )
    except CatchableError as e:
      debug "cache: aborting {e[]}"
      abort()
  try:
    let capts = uriTuple(reqCtx.url.path)
    case capts:
      of (topic: ""):
        info "router: serving homepage rel: {reqCtx.url.path:.20}, fp: {reqCtx.file:.20}, {reqCtx.key}"
        handleHomePage(reqCtx.url.path, capts, ctx)
      of (topic: "assets"):
        logall "router: serving assets {relpath:.20}"
        handleAsset()
      of (topic: "i"):
        logall "router: serving image {relpath:.80}"
        dispatchImg()
      of (topic: "robots.txt"):
        logall "router: serving robots"
        handleRobots()
      of (topic: "feed.xml"):
        info "router: serving site feed"
        handleFeed(fSite)
      of (topic: "sitemap.xml"):
        info "router: serving sitemap"
        handleSitemap(smSite)
      of (topic: "manifest.json"):
        info "router: servinge pwa manifest"
        handlePwa()
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
        handleFeed(fTopic)
      of (page: "sitemap.xml"):
        info "router: serving sitemap for topic {capts.topic:.20}"
        handleSitemap(smTopic)
      of (art: "sitemap.xml"):
        info "router: serving sitemap for topic page {capts.topic:.20}/{capts.page}"
        handleSitemap(smPage)
      of (art: "index.xml"):
        info "router: serving sitemapindex for topic page {capts.topic:.20}"
        handleSitemap(smPageIdx)
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
    reqCtx.cached = true
  except: abort()
  finally:
    reqCtx.rq.del(rqid)
    reqCtx.lock.release
    debug "router: caching req {cast[uint](reqCtx)}"
    # reset(reqCtx.rq)

proc callback(ctx: Request) {.async.} =
  await handleGet(ctx)

template wrapInit(code: untyped): proc() =
  proc task(): void =
    initThread()
    code
  task


proc doServe*(address: string, callback: ScorperCallback): Future[
    Scorper] {.async.} =
  var server = newScorper(address, callback, flags = {ReuseAddr, ReusePort})
  server.start()

  await server.join()
  return server

proc runScorper(address, callback: auto) =
  var srv: Scorper
  try:
    srv = waitFor doServe(address, callback)
  except CatchableError as e:
    warn "server: {e[]} \n restarting server..."
    if not srv.isnil:
      waitFor srv.join()
  except Defect:
    quit!()

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

  while not (adsFirstRead and assetsFirstRead):
    sleep(500)
  # Configure and start server
  # scorper
  let address = "0.0.0.0:" & $serverPort

  while true:
    # Wrap scorper into a proc, to make sure its memory is freed after crashes
    runScorper(address, callback)
    sleep 500
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
