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
       asyncdispatch,
       threadpool,
       httpbeast,
       json

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

const customPages* = ["dmca", "terms-of-service", "privacy-policy"]

type
    ReqContext = object of RootObj
        rq: Request
        url: Uri
        mime: string
        file: string
        key: int64
        headers: HttpHeaders
        norm_capts: UriCaptures
        respHeaders: HttpHeaders
        respBody: string
        respCode: HttpCode

var
    threadInitialized {.threadvar.}: bool
    reqCtxCache {.threadvar.}: LruCache[string, ref ReqContext]

proc initThreadBase*() {.gcsafe, raises: [].} =
    initPy()
    initTypes()
    initLogging()

proc initThread*() {.gcsafe, raises: [].} =
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
    reqCtxCache = newLRUcache[string, ref ReqContext](1000)
    threadInitialized = true

template setEncoding() {.dirty.} =
    debug "detected accepted encoding {headers}"
    let accept = $reqCtx.rq.headers.get["Accept-Encoding"]
    if ("*" in accept) or ("gzip" in accept):
        reqCtx.respHeaders[$hencoding] = "gzip"
        reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfGzip)
    elif "deflate" in accept:
        reqCtx.respHeaders[$hencoding] = "deflate"
        reqCtx.respBody = reqCtx.respBody.compress(dataFormat = dfDeflate)

proc doReply[T](reqCtx: ref ReqContext, body: T, scode = Http200, headers: HttpHeaders = newHttpHeaders()) {.raises: [].} =
    reqCtx.respHeaders = headers
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
    sdebug "reply: sending: {len(reqCtx.respBody)}"
    var tries = 0
    while tries < 3:
        tries += 1
        try:
            reqCtx.respCode = scode
            # assert len(respbody) > 0, "reply: Can't send empty body!"
            reqCtx.rq.send(body = reqCtx.respBody, headers = reqCtx.respHeaders.format, code = reqCtx.respCode)
            break
        except Exception as e:
            sdebug "reply: {getCurrentExceptionMsg()}, {getStackTrace()}"
    sdebug "reply: sent: {len(reqCtx.respBody)}"

proc doReply(reqCtx: ref ReqContext) =
    reqCtx.rq.send(body = reqCtx.respBody, headers = reqCtx.respHeaders.format, code = reqCtx.respCode)

# NOTE: `scorper` crashes when sending empty (`""`) responses, so send code
template handle301*(loc: string = $WEBSITE_URL) {.dirty.} =
    reqCtx.doReply($Http301, scode = Http301, headers = @[("Location", loc)].newHttpHeaders)

template handle404*(loc = $WEBSITE_URL) =
    reqCtx.doReply($Http404, scode = Http404)

template handle501*(loc = $WEBSITE_URL) =
    reqCtx.doReply($Http501, scode = Http501)

template handleHomePage(relpath: string, capts: UriCaptures, ctx: Request) {.dirty.} =
    const homePath = hash(SITE_PATH / "index.html")
    page = pageCache[].lcheckOrPut(reqCtx.key):
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = await buildHomePage(capts.lang, capts.amp)
        pageCache[homePath] = tocache.asHtml(minify_css = (capts.amp == ""))
        toserv.asHtml(minify_css = (capts.amp == ""))
    reqCtx.doReply(page)

import std/asyncfile
proc readFileAsync(path: string, page: ptr string) {.async.} =
    var file = openAsync(path, fmRead)
    defer: file.close()
    page[] = await file.readAll()

proc readFileAsync(path: string): Future[string] {.async.} =
    var file = openAsync(path, fmRead)
    defer: file.close()
    return await file.readAll()

template handleAsset() {.dirty.} =

    when releaseMode:
        reqCtx.mime = mimePath(reqCtx.file)
        try:
            page = pageCache[].get(reqCtx.key)
        except KeyError:
            try:
                await readFileAsync(reqCtx.file, page.addr)
                if page != "":
                    pageCache[reqCtx.key] = page
            except IOError:
                handle404()
    else:
        debug "ASSETS CACHING DISABLED"
        try:
            reqCtx.mime = mimePath(reqCtx.file)
            await readFileAsync(reqCtx.file, page.addr)
        except IOError:
            handle404()
    reqCtx.doReply(page)

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
        try: (page, mime) = handleImg(relpath)
        except: debug "img: could not handle image {relpath}"
        if page != "":
            # append the mimetype before the img data
            pageCache[][reqCtx.key] = mime & ";" & page
            debug "img: save to cache {reqCtx.key} : {relpath}"
    reqCtx.mime = mime
    reqCtx.doReply(page)

template handleTopic(capts: auto, ctx: Request) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topicsCache:
        page = pageCache[].lcheckOrPut(reqCtx.key):
            let
                topic = capts.topic
                pagenum = if capts.page == "": $topic.lastPageNum else: capts.page
            debug "topic: page: ", capts.page
            topicPage(topic, pagenum, false)
            let pageReqKey = (capts.topic / capts.page).fp.hash
            pageCache[pageReqKey] = pagetree.asHtml
            (await processPage(capts.lang, capts.amp, pagetree)).asHtml(minify_css = (capts.amp == ""))
        updateHits(capts)
        reqCtx.doReply(page)
    elif capts.topic in customPages:
        debug "topic: looking for custom page"
        page = pageCache[].lcheckOrPut(reqCtx.key):
            await pageFromTemplate(capts.topic, capts.lang, capts.amp)
        reqCtx.doReply(page)
    else:
        var filename = capts.topic
        filename.removePrefix("/")
        debug "topic: looking for assets {filename}"
        if filename in assetsFiles[]:
            page = pageCache[].lcheckOrPut(filename):
                await readFileAsync(DATA_ASSETS_PATH / filename)
            reqCtx.doReply(page)
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
            reqCtx.doReply(page)
        else:
            debug "article: redirecting to topic because page is empty"
            handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleSearch(relpath: string, ctx: Request) =
    # extract the referer to get the correct language
    let
        refuri = parseUri(if ctx.headers.get().haskey("referer"): $ctx.headers.get[
                "referer"] else: "")
        refcapts = refuri.path.uriTuple
    if capts.lang == "" and refcapts.lang != "":
        handle301($(WEBSITE_URL / refcapts.lang / join(capts, n = 1)))
    else:
        page = searchCache.lcheckOrPut(reqCtx.key):
            # there is no specialized capture for the query
            var searchq = reqCtx.url.query.getParam("q")
            let lang = something(capts.lang, refcapts.lang)
            # this is for js-less form redirection
            if searchq == "" and (not capts.art.startsWith("?")):
                searchq = capts.art.strip()
            (await buildSearchPage(if capts.topic != "s": capts.topic else: "", searchq, lang)).asHtml
        reqCtx.mime = mimePath("index.html")
        reqCtx.doReply(page)

template handleSuggest(relpath: string, ctx: Request) =
    # there is no specialized capture for the query
    let
        prefix = reqCtx.url.query.getParam("p")
        searchq = something(reqCtx.url.query.getParam("q"), capts.art)
    page = await buildSuggestList(capts.topic, searchq, prefix)
    reqCtx.doReply(page)

template handleFeed() =
    page = fetchFeedString(capts.topic)
    reqCtx.doReply(page)

template handleSiteFeed() =
    page = fetchFeedString()
    reqCtx.doReply(page)

template handleTopicSitemap() =
    page = fetchSiteMap(capts.topic)
    reqCtx.doReply(page)

template handleSitemap() =
    page = fetchSiteMap("")
    reqCtx.doReply(page)

template handleRobots() =
    page = pageCache[].lcheckOrPut(reqCtx.key):
        buildRobots()
    reqCtx.doReply(page)

template handleCacheClear() =
    if reqCtx.url.query.getParam("cache") == "0":
        if cached:
            reqCtxCache.del(relpath)
            cached = false
        reqCtx.norm_capts = uriTuple(reqCtx.url.path)
        {.cast(gcsafe).}:
            if reqCtx.norm_capts.art != "":
                debug "cache: deleting article {reqCtx.norm_capts}"
                deleteArt(reqCtx.norm_capts)
            else:
                debug "cache: deleting page {reqCtx.url.path}"
                deletePage(reqCtx.url.path)

template abort() =
    if unlikely(cached):
        reqCtxCache.del(relpath)
    try:
        handle301()
        debug "Router failed, {getCurrentExceptionMsg()}, \n {getStacktrace()}"
    except:
        handle501()

proc handleGet(ctx: Request): Future[bool] {.gcsafe, async.} =
    initThread()
    # doassert ctx.parseRequestLine
    var
        relpath = if ctx.path.isSome(): ctx.path.get() else: ""
        page: string
    relpath.removeSuffix('/')
    var cached = true
    let reqCtx = reqCtxCache.lcheckOrPut(relpath):
        let reqCtx = new(ReqContext)
        parseUri(relpath, reqCtx.url)
        reqCtx.file = reqCtx.url.path.fp
        echo reqCtx.file
        reqCtx.key = hash(reqCtx.file)
        reqCtx.rq = ctx
        cached = false
        reqCtx
    handleCacheClear()
    if cached:
        reqCtx.rq = ctx
        try:
            reqCtx.doReply()
        except:
            reqCtxCache.del(relpath)
            abort()
        return true
    try:
        let capts = uriTuple(relpath)
        case capts:
            of (topic: ""):
                info "router: serving homepage rel: {reqCtx.url.path}, fp: {reqCtx.file}, {reqCtx.key}"
                handleHomePage(reqCtx.url.path, capts, ctx)
            of (topic: "assets"):
                debug "router: serving assets {relpath}"
                handleAsset()
            of (topic: "i"):
                info "router: serving image {relpath}"
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
                info "router: serving search {relpath}"
                handleSearch(relpath, ctx)
            of (topic: "g"):
                info "router: serving suggestion {relpath}"
                handleSuggest(relpath, ctx)
            of (page: "s"):
                info "router: serving search {relpath}"
                handleSearch(relpath, ctx)
            of (page: "g"):
                info "router: serving suggestion {relpath}"
                handleSuggest(relpath, ctx)
            of (page: "feed.xml"):
                info "router: serving feed for topic {capts.topic}"
                handleFeed()
            of (page: "sitemap.xml"):
                info "router: serving sitemap for topic {capts.topic}"
                handleTopicSitemap()
            of (art: ""):
                info "router: serving topic {relpath}, {reqCtx.key}"
                # topic page
                handleTopic(capts, ctx)
            else:
                # Avoid other potential bad urls
                if relpath.len > 0 and capts.art[^1] == relpath[^1]:
                    info "router: serving article {relpath}, {capts}"
                    # article page
                    handleArticle(capts, ctx)
                else:
                    handle301()
    except: abort()
    finally:
        reset(reqCtx.rq)
    # return true

proc callback(ctx: Request) {.async.} =
    asyncCheck handleGet(ctx)
    # let f = threadpool.spawn handleGet(ctx)
    # while not f.isReady:
    #     await sleepAsync(10)
    # discard ^f


template initSpawn(code: untyped, doinit = true) =
    if doinit:
        threadpool.spawn (() => (server.initThread(); code))()
    else:
        threadpool.spawn code

proc start*(doclear = false, port = 0, loglevel = "info") =
    let serverPort = if port == 0:
                         os.getEnv("SITE_PORT", "5050").parseInt
                     else: port
    # main Thread
    initThread()

    initCache()
    initStats()
    readAdsConfig()

    # Publishes new articles for one topic every x seconds
    initSpawn pubTask()

    # cleanup task for deleting low traffic articles
    initSpawn cleanupTask()

    initSpawn runAdsWatcher(), false
    initSpawn runAssetsWatcher(), false

    # Configure and start server
    # let address = "0.0.0.0:" & $serverPort
    # echo fmt"HTTP server listening on port {serverPort}"
    synctopics()
    var settings = initSettings(port = Port(serverPort), bindAddr = "0.0.0.0")
    run(callback, settings = settings)

when isMainModule:
    # initThread()
    # let topic = "vps"
    # let page = buildHomePage("en", "")
    # page.writeHtml(SITE_PATH / "index.html")

    # initSonic()
    # let argt = getLastArticles(topic)
    # echo buildRelated(argt[0])
    pageCache[].clear()
    start()
