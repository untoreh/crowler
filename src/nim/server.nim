import std/[os, times, monotimes, cpuinfo, strformat, strutils, sequtils, json, tables, strtabs, sugar, locks, options, uri, hashes],
       fusion/matching,
       nimpy,
       karax/vdom,
       lrucache,
       zip/zlib,
       chronos,
       chronos_patches,
       chronos/apps/http/[httpserver, httpcommon],
       httputils

{.experimental: "caseStmtMacros".}
{.experimental: "notnil".}

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

import translate except get
from nativehttp import initHttp

const requestSoftTimeout = chronos.timer.seconds(
    100) # Timeout of a request after which a 503 is sent
const requestHardTimeout = chronos.timer.minutes(5) # Max processing time for a request

type
  ParamKey = enum
    none,
    q, p, # sonic
    c,    # cache
    d,    # delete
    t,    # translations
    u     # imgUrls
  Params = Table[ParamKey, string]

  ReqContext = object of RootObj
    rq: Table[ReqId, HttpRequestRef]
    url: uri.Uri
    params: Params
    mime: string
    file: string
    key: string
    norm_capts: UriCaptures
    respHeaders: HttpTable
    respBody: ref string
    respCode: HttpCode
    lock: AsyncLock not nil # this is acquired while the rq is being processed
    cached: bool            # done processing
  ReqId = Hash # using time as request id means that the request cache should be thread local

converter reqPtr(rc: ref ReqContext): uint64 = cast[uint64](rc)

proc getReqId(path: string): ReqId = hash((getMonoTime(), path))

var
  threadInitialized {.threadvar.}: bool
  threadInitLock: Lock
  reqCtxCache {.threadvar.}: LockLruCache[string, ref ReqContext]
  assetsCache {.threadvar.}: LockLruCache[string, string]
  redirectJs {.threadvar.}: string

proc initThreadBase() {.gcsafe.} =
  let configName = os.getenv("CONFIG_NAME")
  initConfig(configName)
  initPy()
  initTypes()
  initCompressor()
  initLogging()
  registerChronosCleanup()

proc initThreadImpl() {.gcsafe.} =
  if threadInitialized:
    debug "thread: already initialized"
    return
  debug "thread: base"
  initThreadBase()
  debug "thread: sonic"
  initSonic() # Must be on top
  debug "thread: http"
  initHttp()
  debug "thread: html"
  initPages()
  initHtml()
  debug "thread: ldj"
  initLDJ()
  debug "thread: feed"
  initFeed()
  debug "thread: img"
  startImgFlow()
  debug "thread: lsh"
  startLsh()
  debug "thread: mimes"
  initMimes()

  debug "thread: amp"
  initAmp()
  debug "thread: trans"
  initTranslate()

  debug "thread: cache"
  reqCtxCache = initLockLruCache[string, ref ReqContext](32)
  assetsCache = initLockLruCache[string, string](32)
  redirectJs = fmt"""<script>window.location.replace("{config.websiteUrl}");</script>"""
  debug "thread: topics"
  initTopics()
  debug "thread: assets"
  loadAssets()
  debug "thread: ads"
  readAdsConfig()

  threadInitialized = true
  debug "thread: initialization complete."

proc initThread*() =
  logall "thread: starting"
  try:
    initLock(threadInitLock)
    withLock(threadInitLock):
      initThreadImpl()
  except:
    logexc()
    warn "Failed to init thread."
    quitl()

template setEncoding() {.dirty.} =
  let rqHeaders = reqCtx.rq[rqid].headers
  debug "reply: declaring accept"
  let accept = $rqHeaders.getString(haccenc)
  if ("*" in accept) or ("gzip" in accept):
    debug "reply: encoding gzip"
    reqCtx.respHeaders.set(hencoding, gz)
    if reqCtx.respBody[] != "":
      debug "reply: compressing body (gzip)"
      let comp = reqCtx.respBody[].compress(stream = GZIP_STREAM)
      reqCtx.respBody[] = comp
  elif "deflate" in accept:
    debug "reply: encoding deflate"
    reqCtx.respHeaders.set(hencoding, defl)
    if reqCtx.respBody[] != "":
      let comp = reqCtx.respBody[].compress(stream = RAW_DEFLATE)
      reqCtx.respBody[] = comp
      debug "reply: compressing body (deflate)"

template setNone(id, val) =
  if id.isNone:
    id.ok(val)

template respond() =

  discard await reqCtx.rq[rqid].respond(
      code = reqCtx.respCode,
      content = reqCtx.respBody[],
      headers = reqCtx.respHeaders,
    )

proc doReply(reqCtx: ref ReqContext, body: string, rqid: ReqId, scode = Http200,
             headers: HttpTable = default(HttpTable)) {.async.} =
  reqCtx.respHeaders = headers
  sdebug "reply: setting body"
  reqCtx.respBody[] =
    if likely(body != ""): body
      else: sdebug "reply: body is empty!"; ""
  let size = len(reqCtx.respBody[])
  if reqCtx.mime == "":
    sdebug "reply: mimepath"
    reqCtx.mime = mimePath(reqCtx.file)
  sdebug "reply: setting mime"
  reqCtx.respHeaders.set(hcontent, reqCtx.mime)
  try:
    sdebug "reply: encoding type header"
    if sre("^(?:text)|(?:image)|(?:application)/") in reqCtx.mime:
      setEncoding
    debug "reply: headers -- {reqCtx.respHeaders}"
    reqCtx.respHeaders.set(hetag, '"' & $(reqCtx.respBody[].hash) & '"')
  except:
    swarn "reply: troubles serving page {reqCtx.file}"
    sdebug "reply: sending: {size} to {reqCtx.url}"
  try:
    reqCtx.respCode = scode
    # assert len(respbody) > 0, "reply: Can't send empty body!"
    debug "reply: sending response {reqCtx.key}"
    respond()
    sdebug "reply: sent: {size}"
  except:
    logexc()
    sdebug "reply: failed."

proc doReply(reqCtx: ref ReqContext, rqid: ReqId) {.async.} = respond()

{.push dirty.}

template ifHtml(els): string =
  if reqCtx.mime == "text/html": redirectJs
  else: $els

template handle301*(loc: string = $config.websiteUrl) =
  let headers = init(HttpTable, [($hloc, loc)])
  # headers[$hloc] = loc
  block:
    logexc()
    debug "server: redirecting."
    await reqCtx.doReply(ifHtml(Http301), rqid, scode = Http301,
        headers = headers)

template handle404*(loc = $config.websiteUrl) =
  await reqCtx.doReply(ifHtml(Http404), rqid, scode = Http404)

template handle503*(loc = $config.websiteUrl) =
  await reqCtx.doReply(ifHtml(Http503), rqid, scode = Http503,
                       headers = init(HttpTable, [($hretry, "28800")]))

template abort(m: string) =
  debug m & ", aborting."
  logexc()
  sdebug "Router failed."
  handle503()
  if unlikely(reqCtx.cached):
    reqCtx.cached = false
    reqCtx.respBody[].setLen(0)
    reset(reqCtx.respHeaders)
    reset(reqCtx.respCode)

import htmlparser, xmltree
template handleHomePage(relpath: string, capts: UriCaptures,
    ctx: HttpRequestRef) =
  page = getOrCache(reqCtx.key):
    let tree = await buildHomePage(capts.lang, capts.amp)
    checkNil tree, "homepage: page tree is nil"
    let hpage = tree.asHtml(minify_css = (capts.amp == ""))
    checkTrue hpage.len > 0, "homepage: minification 1 failed"
    hpage
  await reqCtx.doReply(page, rqid)

template handleAsset() =

  when not defined(noAssetsCaching):
    reqCtx.mime = mimePath(reqCtx.file)
    try:
      page = assetsCache.get(reqCtx.key)
      await reqCtx.doReply(page, rqid, )
    except [KeyError, ValueError]:
      try:
        page = await readFileAsync(reqCtx.file)
        if page != "":
          assetsCache[reqCtx.key] = page
          await reqCtx.doReply(page, rqid, )
        else:
          handle301()
      except:
        handle301()
  else:
    debug "ASSETS CACHING DISABLED"
    try:
      reqCtx.mime = mimePath(reqCtx.file)
      page = await readFileAsync(reqCtx.file)
      await reqCtx.doReply(page, rqid, )
    except:
      handle301()

proc imgFile(reqCtx: ref ReqContext): string {.inline.} =
  result = reqCtx.url.path & "?" & reqCtx.url.query
  # fix for image handling, since images use queries, therefore paths are not unique
  result.removePrefix("/i")

proc imgKey(reqCtx: ref ReqContext): string {.inline.} = reqCtx.imgFile

template dispatchImg() =
  var mime: string
  reqCtx.file = reqCtx.imgFile
  reqCtx.key = reqCtx.imgKey
  try:
    (mime, page) = imgCache.get(reqCtx.key).split(";", maxsplit = 1)
    debug "img: fetched from cache {reqCtx.key} {reqCtx.file}"
  except KeyError, AssertionDefect:
    debug "img: not found handling image, {reqCtx.file}"
    try: (page, mime) = await handleImg(reqCtx.file)
    except:
      logexc()
      debug "img: could not handle image {reqCtx.file}."
    if page != "":
      # append the mimetype before the img data
      imgCache[reqCtx.key] = mime & ";" & page
      debug "img: saved to cache {reqCtx.key} : {reqCtx.url}"
  if page != "":
    reqCtx.mime = mime
    let headers = init(HttpTable, [($hcctrl, "2678400s")])
  else:
    reqCtx.mime = config.defaultImageMime
    page = defaultImageData
  await reqCtx.doReply(page, rqid, )

template handleTopic(capts: auto, ctx: HttpRequestRef) =
  debug "topic: looking for {capts.topic}"
  if capts.topic in topicsCache:
    page = getOrCache(reqCtx.key):
      let topic = capts.topic
      var istop = false
      let pagenum = if capts.page == "":
                      istop = true
                      $(await topic.lastPageNum)
                    else: capts.page
      debug "topic: page: ", capts.page
      topicPage(topic, pagenum, istop, lng = capts.lang)
      checkNil pagetree, "topic: pagetree couldn't be generated."
      let
        pagepath = capts.topic / capts.page
        pageReqKey = pagepath.fp
      var ppage = pagetree.asHtml
      checkTrue ppage.len > 0, "topic: page gen 1 failed."
      pageCache[pageReqKey] = ppage
      ppage = ""
      checkNil(pagetree):
        let path = join([capts.topic, capts.page], "/")
        let processed = await processPage(capts.lang, capts.amp, pagetree,
            relpath = capts.path)
        checkNil(processed):
          ppage = processed.asHtml(minify_css = (capts.amp == ""))
      checkTrue ppage.len > 0, "topic: page gen 2 failed."
      ppage
    updateHits(capts)
    await reqCtx.doReply(page, rqid, )
  elif capts.topic in config.websiteCustomPages:
    debug "topic: looking for custom page"
    page = getOrCache(reqCtx.key):
      let ppage = await pageFromTemplate(capts.topic, capts.lang, capts.amp)
      checkTrue ppage.len > 0, "topic custom page gen failed."
      ppage
    await reqCtx.doReply(page, rqid, )
  else:
    var filename = capts.topic.extractFilename()
    debug "topic: looking for assets {filename:.120}"
    if filename in assetsFiles:
      page = getOrCache(filename):
        # allow to cache this unconditionally of the file existing or not
        await readFileAsync(config.dataAssetsPath / filename)
      await reqCtx.doReply(page, rqid, )
    else:
      debug "topic: asset not found at {config.dataAssetsPath / filename:.120}"
      handle301()

template handleArticle(capts: auto, ctx: HttpRequestRef) =
  ##
  debug "article: fetching article"
  let tg = topicsCache.get(capts.topic, emptyTopic[])
  if tg.topdir != -1:
    checkNil(tg.group)
    try:
      page = getOrCache(reqCtx.key):
        debug "article: generating article"
        let ppage = await articleHtml(capts)
        checkTrue ppage.len > 0, "article: page gen failed."
        ppage
      updateHits(capts)
      await reqCtx.doReply(page, rqid, )
    except ValueError:
      debug "article: redirecting to topic because page is empty"
      handle301()
      # handle301($(config.websiteUrl / capts.amp / capts.lang / capts.topic))
  else:
    handle301()
    # handle301($(config.websiteUrl / capts.amp / capts.lang))

template handleSearch(ctx: HttpRequestRef) =
  # extract the referer to get the correct language
  let
    refuri = parseUri(ctx.headers.getString(href))
    refcapts = refuri.path.uriTuple
  if capts.lang == "" and refcapts.lang != "":
    handle301($(config.websiteUrl / refcapts.lang / join(capts, n = 1)))
  else:
    page = searchCache.lcheckOrPut(reqCtx.key):
      # there is no specialized capture for the query
      let lang = something(capts.lang, refcapts.lang)
      # this is for js-less form redirection
      let searchq = reqCtx.params.getOrDefault(ParamKey.q, capts.art.strip())
      let ppage =
        block:
          let tp =
            if capts.topic != "s": capts.topic
            else: ""
          (await buildSearchPage(tp, searchq, lang, capts)).asHtml
      checkTrue ppage.len > 0, "search: page gen failed."
      ppage
    reqCtx.mime = mimePath("index.html")
    await reqCtx.doReply(page, rqid, )

template handleSuggest(ctx: HttpRequestRef) =
  # there is no specialized capture for the query
  let
    prefix = reqCtx.params.getOrDefault(ParamKey.p, "")
    searchq = reqCtx.params.getOrDefault(ParamKey.q, capts.art)
  logall "suggest: searchq -- {searchq}"
  page = await buildSuggestList(capts.topic, searchq, prefix)
  await reqCtx.doReply(page, rqid, )

template handlePwa() =
  page = getOrCache(reqCtx.key):
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
  page = getOrCache(reqCtx.key):
    let ppage = buildRobots()
    checkTrue ppage.len > 0, "robots: page gen failed."
    ppage
  await reqCtx.doReply(page, rqid, )

proc reset(reqCtx: ref ReqContext) =
  reqCtx.cached = false
  reqCtx.respBody[].setLen(0)
  reqCtx.respHeaders.reset
  reqCtx.respCode.reset
  if reqCtx.lock.locked:
    reqCtx.lock.release

template handleCacheClear() =
  if not cacheParam.isnull:
    case cacheParam:
      of '0':
        const notTopics = ["assets", "i", "robots.txt", "feed.xml", "index.xml",
            "sitemap.xml", "s", "g"].toHashSet
        reqCtx.reset()
        reqCtx.norm_capts = uriTuple(reqCtx.url.path)
        try:
          if reqCtx.norm_capts.art != "" and
            (reqCtx.norm_capts.topic notin notTopics) and
            (reqCtx.norm_capts.page notin notTopics):
            debug "cache: deleting article cache {reqCtx.norm_capts.art:.40}"
            await deleteArt(reqCtx.norm_capts, cacheOnly = true)
          elif reqCtx.norm_capts.topic == "i":
            imgCache.del(reqCtx.imgKey)
          elif reqCtx.norm_capts.topic == "assets":
            assetsCache.del(reqCtx.key)
          elif "sitemap.xml" in reqCtx.norm_capts or "index.xml" in
              reqCtx.norm_capts:
            let capts = reqCtx.norm_capts
            if capts.topic == "sitemap.xml":
              clearSiteMap()
            elif capts.page == "sitemap.xml":
              clearSiteMap(capts.topic)
            elif capts.art == "sitemap.xml":
              clearSiteMap(capts.topic, capts.page)
            elif capts.art == "index.ml":
              clearSiteMap(capts.topic, true)
          elif "feed.xml" in reqCtx.norm_capts:
            let capts = reqCtx.norm_capts
            if capts.topic == "feed.xml":
              clearFeed()
            else:
              clearFeed(capts.topic)
          else:
            debug "cache: deleting page {reqCtx.url.path}"
            pageCache.del(reqCtx.key)
            if reqCtx.norm_capts.topic notin notTopics:
              deletePage(reqCtx.norm_capts)
        except:
          warn "cache: deletion failed for {reqCtx.norm_capts:.120}"
      of '1':
        pageCache.clear()
        reqCtxCache.clear() # FIXME: should account for running requests...
        warn "cache: cleared all pages"
      else:
        discard

proc parseParams(url: var Uri): Params =
  result = initTable[ParamKey, string]()
  for (k, v) in url.query.decodeQuery:
    let par: ParamKey = parseEnum(k, none)
    result[par] = v
  if none in result:
    result.del(none)

template handleParams() =
  # parse url and check cache key
  var
    url = ctx.uri
    cacheParam: char
    transParam: char
    delParam: char

  var params = parseParams(url)
  if c in params:
    cacheParam = params[c][0]
    params.del(c)
  if t in params:
    transParam = params[t][0]
    params.del(t)
  if d in params:
    delParam = params[d][0]
    params.del(d)
  let pars = collect(for (k, v) in params.pairs(): ($k, v))
  url.query = encodeQuery(pars)

template handleTranslation(): bool =
  if not transParam.isnull:
    try:
      let tree = await processTranslatedPage(capts.lang, capts.amp,
          relpath = capts.path)
      page = tree.asHtml(minify_css = (capts.amp == ""))
      pageCache[reqCtx.key] = page
      await reqCtx.doReply(page, rqid)
      reqCtx.cached = true
      true
    except:
      logexc()
      if reqCtx.respBody[].len > 0:
        await reqCtx.doReply(rqid)
        true
      else:
        cacheParam = '0'
        handleCacheClear()
        false
  else:
    false

template handleDeletion(): bool =
  var ret = false
  if not delParam.isnull:
    defer:
      ret = true
      abort("deleted")
    var capts = uriTuple(reqCtx.url.path)
    if capts.art.len > 0:
      await deleteArt(capts)
    else:
      deletePage(capts)
    block:
      template doReset(pref) =
        for enc in ["gzip", "deflate", "gzip, deflate"]:
          let rck = pref & enc
          if rck in reqCtxCache:
            if reqCtxCache[rck].isnil:
              reqCtxCache.del(rck)
            else:
              await reqCtxCache[rck].lock.acquire()
              reqCtxCache[rck].reset()
      # Delete main topic page
      capts.art = ""
      deletePage(capts)
      doReset(capts.path(slash = true))
      # delete homepage
      deletePage("")
      doReset("/")
  ret

{.pop dirty.}

template isTranslationReq(): bool = transParam != '\0'

proc handleGet(ctx: HttpRequestRef): Future[void] {.gcsafe, async.} =
  defer:
    # FIXME: is this cleanup required?
    var futs: seq[Future[void]]
    let resp =
      if ctx.response.issome: ctx.response.get
      else: nil
    if not resp.isnil and not resp.connection.isnil:
      futs.add resp.connection.closeWait()
    if not ctx.isnil:
      if not ctx.connection.isnil:
        futs.add ctx.connection.closeWait()
      futs.add ctx.closeWait()
    await allFutures(futs)

  initThread()
  # doassert ctx.parseRequestLine
  var
    relpath = ctx.rawPath
    page: string
    rqlocked: bool
  relpath.removeSuffix('/')
  debug "handling: {relpath:.120}"

  handleParams()

  # generate request super context
  let acceptEncodingStr = ctx.headers.getString(haccenc)
  let reqCacheKey = $(url.path & url.query & acceptEncodingStr)
  let reqCtx = reqCtxCache.lcheckOrPut(reqCacheKey):
    let reqCtx {.gensym.} = new(ReqContext)
    block:
      let l = newAsyncLock()
      checkNil(l):
        reqCtx.lock = l
    reqCtx.url = move url
    reqCtx.params = params
    reqCtx.file = reqCtx.url.path.fp
    reqCtx.key = reqCtx.file
    reqCtx.rq = initTable[ReqId, HttpRequestRef]()
    new(reqCtx.respBody)
    reqCtx
  # don't replicate works on unfinished requests
  if not reqCtx.cached:
    await reqCtx.lock.acquire
    rqlocked = true
  defer:
    if not reqCtx.isnil and rqlocked and
        reqCtx.lock.locked: # `handleDeletion` could have cleared the lock
      reqCtx.lock.release
    # after lock acquisition reqCtx could have been swiched to `cached`
  let rqid = getReqId(relpath)
  reqCtx.rq[rqid] = ctx
  defer:
    if not reqCtx.isnil:
      if rqid in reqCtx.rq:
        reqCtx.rq.del(rqid)

  if handleDeletion():
    # NOTE: this can't be put inside the template...
    return
  handleCacheClear()

  if reqCtx.cached and not isTranslationReq():
    try:
      logall "cache: serving cached reply, {reqCtx.key} addr: {cast[uint](reqCtx)}"
      await reqCtx.doReply(rqid, )
    except:
      logexc()
      abort("cache")
    return

  try:
    let capts = uriTuple(reqCtx.url.path)
    if handleTranslation():
      return
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
        handleSearch(ctx)
      of (topic: "g"):
        info "router: serving suggestion {relpath:.20}"
        handleSuggest(ctx)
      of (page: "s"):
        info "router: serving search {relpath:.20}"
        handleSearch(ctx)
      of (page: "g"):
        info "router: serving suggestion {relpath:.20}"
        handleSuggest(ctx)
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
  except:
    logexc()
    abort("capts")
  finally:
    debug "router: caching req {reqCtx.key}"

proc callback(ctx: RequestFence): Future[HttpResponseRef] {.async.} =
  if likely(not ctx.iserr):
    let rq = ctx.get
    if rq.meth == MethodGet:
      let fut = handleGet(rq)
      raceAndCheck(fut, requestSoftTimeout, requestHardTimeout)
      if rq.response.issome:
        # Prevent connections from being kept alive to reduce load
        let resp = rq.getResponse()
        resp.state = HttpResponseState.Empty # HACK: can't set keepalive if state is not empty
        resp.keepalive = false
        resp.state = HttpResponseState.Finished
        return resp

template wrapInit(code: untyped): proc() =
  proc task(): void =
    initThread()
    code
  task

proc doServe*(address: string, callback: HttpProcessCallback) =
  let ta = resolveTAddress(address)[0]
  let srv =
    HttpServerRef.new(ta, callback).get
  try:
    srv.start()
    waitFor srv.join()
  except:
    logexc()
  finally:
    if not srv.isnil:
      waitfor srv.closeWait()

proc startServer*(doclear = false, port = 0, loglevel = "info") =

  initThread()
  initCache(doclear)
  initStats()
  initAds()

  # runTasks(@[mem, cleanup, tpc])
  runTasks(@[mem])


  checkNil config
  let serverPort =
    if port == 0: config.websitePort
    else: port
  # Configure and start server
  let address = "0.0.0.0:" & $serverPort

  while true:
    # Wrap server into a proc, to make sure its memory is freed after crashes
    info "server: starting..."
    doServe(address, callback)
    warn "server: closed..."
    sleep 500
  # httpbeast
  # var settings = initSettings(port = Port(serverPort), bindAddr = "0.0.0.0")
  # run(callback, settings = settings)

