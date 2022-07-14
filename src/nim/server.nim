import strformat,
       sugar,
       strutils,
       tables,
       nimpy,
       std/os,
       times,
       locks,
       karax/vdom,
       strtabs,
       nre,
       options,
       fusion/matching,
       uri,
       lrucache,
       zippy,
       hashes,
       chronos,
       scorper,
       scorper/http/httpcore,
       std/cpuinfo,
       taskpools,
       json,
       faststreams/inputs

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


type
    ReqContext = object of RootObj
        rq: ptr Request
        url: Uri
        mime: string
        file: string
        key: int64
        headers: HttpHeaders
        norm_capts: UriCaptures
        respHeaders: HttpHeaders
        respBody: string
        respCode: HttpCode
        cached: bool

var
    threadInitialized {.threadvar.}: bool
    reqCtxCache {.threadvar.}: LockLruCache[string, ref ReqContext]

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
    initWrapImageFlow()
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
    waitFor syncTopics()
    threadInitialized = true

let emptyHttpValues = create(HttpHeaderValues)
emptyHttpValues[] = @[""].HttpHeaderValues
let emptyHttpHeaders = create(HttpHeaders)
emptyHttpHeaders[] = newHttpHeaders()

template setEncoding() {.dirty.} =
    assert not reqCtx.rq.isnil
    let rqHeaders = reqCtx.rq[].headers
    assert not rqHeaders.isnil
    let accept = $(rqHeaders.getOrDefault("Accept-Encoding", deepcopy(emptyHttpValues[])))
    if ("*" in accept) or ("gzip" in accept):
        reqCtx.respHeaders[$hencoding] = "gzip"
        if reqCtx.respBody != "":
            reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfGzip)
    elif "deflate" in accept:
        reqCtx.respHeaders[$hencoding] = "deflate"
        if reqCtx.respBody != "":
            reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfDeflate)

proc doReply(reqCtx: ref ReqContext, body: string, scode = Http200,
             headers: HttpHeaders = nil) {.async.} =
    reqCtx.respHeaders = if headers.isnil: deepcopy(emptyHttpHeaders[])
                         else: headers
    reqCtx.respBody = if likely(body != ""): body
               else:
                   sdebug "reply: body is empty!"
                   ""
    if reqCtx.mime == "":
        reqCtx.mime = mimePath(reqCtx.file)
    reqCtx.respHeaders[$hcontent] = reqCtx.mime
    try:
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
        await reqCtx.rq[].resp(content = reqCtx.respBody, headers = reqCtx.respHeaders, code = reqCtx.respCode)
        sdebug "reply: sent: {len(reqCtx.respBody)}"
    except Exception as e:
        sdebug "reply: {getCurrentExceptionMsg()}, {getStackTrace()}"

proc doReply(reqCtx: ref ReqContext) {.async.} =
    await reqCtx.rq[].resp(content = reqCtx.respBody, headers = reqCtx.respHeaders, code = reqCtx.respCode)

# NOTE: `scorper` crashes when sending empty (`""`) responses, so send code
template handle301*(loc: string = $WEBSITE_URL) {.dirty.} =
    reqCtx.respHeaders = @[("Location", loc)].newHttpHeaders
    await reqCtx.doReply($Http301, scode = Http301)

template handle404*(loc = $WEBSITE_URL) =
    await reqCtx.doReply($Http404, scode = Http404)

template handle501*(loc = $WEBSITE_URL) =
    await reqCtx.doReply($Http501, scode = Http501)

template handleHomePage(relpath: string, capts: UriCaptures, ctx: Request) {.dirty.} =
    const homePath = hash(SITE_PATH / "index.html")
    page = pageCache[].lcheckOrPut(reqCtx.key):
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = await buildHomePage(capts.lang, capts.amp)
        pageCache[homePath] = tocache.asHtml(minify_css = (capts.amp == ""))
        toserv.asHtml(minify_css = (capts.amp == ""))
    await reqCtx.doReply(page)

template handleAsset() {.dirty.} =

    var data: seq[byte]
    when releaseMode:
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
    await reqCtx.doReply(page)

template dispatchImg(relpath: var string, ctx: auto) {.dirty.} =
    var mime: string
    try:
        relpath.removePrefix("/i")
        # fix for image handling, since images use queries, therefore paths are not unique
        reqCtx.file = reqCtx.url.path & reqCtx.url.query
        reqCtx.key = hash(reqcTx.file)
        (mime, page) = pageCache[].get(reqCtx.key).split(";", maxsplit = 1)
        debug "img: fetched from cache {reqCtx.key} {relpath}"
    except KeyError, AssertionDefect:
        try: (page, mime) = await handleImg(relpath)
        except: debug "img: could not handle image {relpath}"
        if page != "":
            # append the mimetype before the img data
            pageCache[][reqCtx.key] = mime & ";" & page
            debug "img: save to cache {reqCtx.key} : {relpath}"
    reqCtx.mime = mime
    await reqCtx.doReply(page)

template handleTopic(capts: auto, ctx: Request) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topicsCache:
        page = pageCache[].lcheckOrPut(reqCtx.key):
            let topic = capts.topic
            let pagenum = if capts.page == "": $(await topic.lastPageNum()) else: capts.page
            debug "topic: page: ", capts.page
            topicPage(topic, pagenum, false)
            let pageReqKey = (capts.topic / capts.page).fp.hash
            pageCache[pageReqKey] = pagetree.asHtml
            (await processPage(capts.lang, capts.amp, pagetree)).asHtml(minify_css = (capts.amp == ""))
        updateHits(capts)
        await reqCtx.doReply(page)
    elif capts.topic in customPages:
        debug "topic: looking for custom page"
        page = pageCache[].lcheckOrPut(reqCtx.key):
            await pageFromTemplate(capts.topic, capts.lang, capts.amp)
        await reqCtx.doReply(page)
    else:
        var filename = capts.topic
        filename.removePrefix("/")
        debug "topic: looking for assets {filename}"
        if filename in assetsFiles[]:
            page = pageCache[].lcheckOrPut(filename):
                await readFileAsync(DATA_ASSETS_PATH / filename)
            await reqCtx.doReply(page)
        else:
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
            await reqCtx.doReply(page)
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
            (await buildSearchPage(if capts.topic != "s": capts.topic else: "", searchq, lang)).asHtml
        reqCtx.mime = mimePath("index.html")
        await reqCtx.doReply(page)

template handleSuggest(relpath: string, ctx: Request) =
    # there is no specialized capture for the query
    let
        prefix = reqCtx.url.query.getParam("p")
        searchq = something(reqCtx.url.query.getParam("q"), capts.art)
    page = await buildSuggestList(capts.topic, searchq, prefix)
    await reqCtx.doReply(page)

template handleFeed() =
    page = await fetchFeedString(capts.topic)
    await reqCtx.doReply(page)

template handleSiteFeed() =
    page = await fetchFeedString()
    await reqCtx.doReply(page)

template handleTopicSitemap() =
    page = await fetchSiteMap(capts.topic)
    await reqCtx.doReply(page)

template handleSitemap() =
    page = await fetchSiteMap("")
    await reqCtx.doReply(page)

template handleRobots() =
    page = pageCache[].lcheckOrPut(reqCtx.key):
        buildRobots()
    await reqCtx.doReply(page)

template handleCacheClear() =
    if reqCtx.url.query.getParam("cache") == "0":
        if reqCtx.cached:
            reqCtx.cached = false
        reqCtx.norm_capts = uriTuple(reqCtx.url.path)
        {.cast(gcsafe).}:
            if reqCtx.norm_capts.art != "":
                debug "cache: deleting article cache {reqCtx.norm_capts:.40}"
                await deleteArt(reqCtx.norm_capts, cacheOnly=true)
            else:
                debug "cache: deleting page {reqCtx.url.path}"
                deletePage(reqCtx.url.path)

template abort() =
    if unlikely(reqCtx.cached):
        reqCtxCache.del(relpath)
    try:
        handle301()
        debug "Router failed, Exception: \n {getCurrentExceptionMsg()}, \n Stacktrace: \n {getStacktrace()}"
    except:
        handle501()

proc handleGet(ctx: Request): Future[bool] {.gcsafe, async.} =
    initThread()
    # doassert ctx.parseRequestLine
    var
        relpath = ctx.path
        page: string
    relpath.removeSuffix('/')
    debug "handling: {relpath:.20}"
    let reqCtx = reqCtxCache.lcheckOrPut(relpath):
        let reqCtx = new(ReqContext)
        parseUri(relpath, reqCtx.url)
        reqCtx.file = reqCtx.url.path.fp
        reqCtx.key = hash(reqCtx.file)
        reqCtx
    reqCtx.rq = ctx.unsafeAddr
    handleCacheClear()
    if reqCtx.cached:
        try:
            logall "cache: serving cached reply"
            await reqCtx.doReply()
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
                info "router: serving image {relpath:.20}"
                dispatchImg(relpath, ctx)
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
        # reset(reqCtx.rq)

proc callback(ctx: Request) {.async.} =
    discard await handleGet(ctx)

template wrapInit(code: untyped): proc() =
    proc task(): void =
        initThread()
        code
    task

when declared(Taskpool):
    var tp = Taskpool.new(num_threads = 2)
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

    initSpawn runAdsWatcher(), false
    initSpawn runAssetsWatcher(), false

    # Configure and start server
    # scorper
    let address = "0.0.0.0:" & $serverPort
    waitFor serve(address, callback)
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
