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
    opg,
    ldj,
    imageflow_server,
    cache,
    search,
    sitemap,
    articles,
    stats

const customPages* = ["dmca", "terms-of-service", "privacy-policy"]
const nobody = ""
var
    reqMime {.threadvar.}: string
    reqFile {.threadvar.}: string
    reqKey {.threadvar.}: int64
    threadInitialized {.threadvar.}: bool


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
    threadInitialized = true

template setEncoding() {.dirty.} =
    debug "detected accepted encoding {headers}"
    let accept = $ctx.headers.get["Accept-Encoding"]
    if ("*" in accept) or ("gzip" in accept):
        hencoding.add("gzip")
        respbody = respbody.compress(dataFormat = dfGzip)
    elif "deflate" in accept:
        hencoding.add("deflate")
        respbody = respbody.compress(dataFormat = dfDeflate)

proc doReply[T](ctx: Request, body: T, scode = Http200, headers: openarray[string] = @[
        ]) {.raises: [].} =
    baseHeaders.add headers
    var respbody = if likely(body != ""): body
               else:
                   sdebug "reply: body is empty!"
                   ""
    if reqMime == "":
        reqMime = mimePath(reqFile)
    hcontent.add reqMime
    try:
        if sre("^(?:text)|(?:image)|(?:application)/") in reqMime:
            setEncoding
        debug "reply: headers -- {baseHeaders}"
        hetag.add '"' & $reqKey & '"'
    except:
        swarn "reply: troubles serving page {reqFile}"
    sdebug "reply: sending: {len(respbody)}"
    var success = false
    while not success:
        try:
            let httpHeaders = baseHeaders.format
            # assert len(respbody) > 0, "reply: Can't send empty body!"
            ctx.send(body = respbody, headers = httpHeaders, code = scode)
            success = true
        except Exception as e:
            sdebug "reply: {getCurrentExceptionMsg()}, {getStackTrace()}"
    sdebug "reply: sent: {len(respbody)}"

# NOTE: `scorper` crashes when sending empty (`""`) responses, so send code
template handle301*(loc: string = $WEBSITE_URL) {.dirty.} =
    const body = "301"
    ctx.doReply(body, scode = Http301, headers = ["Location: " & loc])

template handle404*(loc = $WEBSITE_URL) =
    const body = "404"
    ctx.doReply(body, scode = Http404)

template handle501*(loc = $WEBSITE_URL) =
    const body = "501"
    ctx.doReply(body, scode = Http501)

template handleHomePage(relpath: string, capts: UriCaptures, ctx: Request) {.dirty.} =
    const homePath = hash(SITE_PATH / "index.html")
    page = pageCache[].lcheckOrPut(reqKey):
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = await buildHomePage(capts.lang, capts.amp)
        pageCache[homePath] = tocache.asHtml(minify_css = (capts.amp == ""))
        toserv.asHtml(minify_css = (capts.amp == ""))
    ctx.doReply(page)

import std/asyncfile
proc readFileAsync(path: string, page: ptr string) {.async.} =
    var file = openAsync(path, fmRead)
    defer: file.close()
    page[] = await file.readAll()

template handleAsset() {.dirty.} =

    when releaseMode:
        reqMime = mimePath(reqFile)
        try:
            page = pageCache[].get(reqKey)
        except KeyError:
            try:
                await readFileAsync(reqFile, page.addr)
                if page != "":
                    pageCache[reqKey] = page
            except IOError:
                handle404()
    else:
        debug "ASSETS CACHING DISABLED"
        try:
            reqMime = mimePath(reqFile)
            await readFileAsync(reqFile, page.addr)
        except IOError:
            handle404()
    ctx.doReply(page)

template dispatchImg(relpath: var string, ctx: auto) {.dirty.} =
    var mime: string
    try:
        relpath.removePrefix("/i")
        (mime, page) = pageCache[].get(reqKey).split(";", maxsplit = 1)
    except KeyError, AssertionDefect:
        try: (page, mime) = handleImg(relpath)
        except: debug "server: could not handle image {relpath}"
        if likely(page != ""):
            # append the mimetype before the img data
            pageCache[][reqKey] = mime & ";" & page
    reqMime = mime
    ctx.doReply(page)

template handleTopic(capts: auto, ctx: Request) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topicsCache:
        page = pageCache[].lcheckOrPut(reqKey):
            let
                topic = capts.topic
                pagenum = if capts.page == "": $topic.lastPageNum else: capts.page
            debug "topic: page: ", capts.page
            topicPage(topic, pagenum, false)
            let pageReqKey = (capts.topic / capts.page).fp.hash
            pageCache[pageReqKey] = pagetree.asHtml
            (await processPage(capts.lang, capts.amp, pagetree)).asHtml(minify_css = (capts.amp == ""))
        updateHits(capts)
        ctx.doReply(page)
    elif capts.topic in customPages:
        page = pageCache[].lcheckOrPut(reqKey):
            await pageFromTemplate(capts.topic, capts.lang, capts.amp)
        ctx.doReply(page)
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleArticle(capts: auto, ctx: Request) =
    ##
    debug "article: fetching article"
    let tg = topicsCache.get(capts.topic, emptyTopic)
    if tg.topdir != -1:
        page = pageCache[].lcheckOrPut(reqKey):
            debug "article: generating article"
            await articleHtml(capts)
        if page != "":
            updateHits(capts)
            ctx.doReply(page)
        else:
            debug "article: redirecting to topic because page is empty"
            handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleSearch(relpath: string, ctx: Request) =
    # extract the referer to get the correct language
    let
        refuri = parseUri(ctx.headers.get["referer"])
        refcapts = refuri.path.uriTuple
    if capts.lang == "" and refcapts.lang != "":
        handle301($(WEBSITE_URL / refcapts.lang / join(capts, n = 1)))
    else:
        page = searchCache.lcheckOrPut(reqKey):
            # there is no specialized capture for the query
            var searchq = parseUri(capts.art).query.getParam("q")
            let lang = something(capts.lang, refcapts.lang)
            # this is for js-less form redirection
            if searchq == "" and (not capts.art.startsWith("?")):
                searchq = capts.art.strip()
            (await buildSearchPage(if capts.topic != "s": capts.topic else: "", searchq, lang)).asHtml
        reqMime = mimePath("index.html")
        ctx.doReply(page)

template handleSuggest(relpath: string, ctx: Request) =
    # there is no specialized capture for the query
    let
        purl = parseUri(capts.art)
        prefix = purl.query.getParam("p")
        searchq = something(purl.query.getParam("q"), capts.art)
    page = await buildSuggestList(capts.topic, searchq, prefix)
    ctx.doReply(page)

template handleFeed() =
    page = fetchFeedString(capts.topic)
    ctx.doReply(page)

template handleSiteFeed() =
    page = fetchFeedString()
    ctx.doReply(page)

template handleTopicSitemap() =
    page = fetchSiteMap(capts.topic)
    ctx.doReply(page)

template handleSitemap() =
    page = fetchSiteMap("")
    ctx.doReply(page)

template handleRobots() =
    page = pageCache[].lcheckOrPut(reqKey):
        buildRobots()
    ctx.doReply(page)

proc handleGet(ctx: Request): Future[bool] {.gcsafe, async.} =
    initThread()
    # doassert ctx.parseRequestLine
    reset(reqMime)
    reset(reqFile)
    reset(reqKey)
    resetHeaders()
    var
        relpath = if ctx.path.isSome(): ctx.path.get() else: ""
        page: string
    relpath.removeSuffix('/')
    reqFile = relpath.fp
    reqKey = hash(reqFile)
    try:
        let capts = uriTuple(relpath)
        case capts:
            of (topic: ""):
                debug "router: serving homepage rel: {relpath}, fp: {reqFile}"
                handleHomePage(relpath, capts, ctx)
            of (topic: "assets"):
                # debug "router: serving assets {relpath}"
                handleAsset()
            of (topic: "i"):
                # debug "router: serving image {relpath}"
                dispatchImg(relpath, ctx)
            of (topic: "robots.txt"):
                debug "router: serving robots"
                handleRobots()
            of (topic: "feed.xml"):
                debug "router: serving site feed"
                handleSiteFeed()
            of (topic: "sitemap.xml"):
                debug "router: serving sitemap"
                handleSitemap()
            of (topic: "s"):
                debug "router: serving search {relpath}"
                handleSearch(relpath, ctx)
            of (topic: "g"):
                debug "router: serving suggestion {relpath}"
                handleSuggest(relpath, ctx)
            of (page: "s"):
                debug "router: serving search {relpath}"
                handleSearch(relpath, ctx)
            of (page: "g"):
                debug "router: serving suggestion {relpath}"
                handleSuggest(relpath, ctx)
            of (page: "feed.xml"):
                debug "router: serving feed for topic {capts.topic}"
                handleFeed()
            of (page: "sitemap.xml"):
                debug "router: serving sitemap for topic {capts.topic}"
                handleTopicSitemap()
            of (art: ""):
                debug "router: serving topic {relpath}"
                # topic page
                handleTopic(capts, ctx)
            else:
                # Avoid other potential bad urls
                if capts.art[^1] == relpath[^1]:
                    debug "router: serving article {relpath}, {capts}"
                    # article page
                    handleArticle(capts, ctx)
                else:
                    handle301()
    except:
        try:
            let msg = getCurrentExceptionMsg()
            handle301()
            debug "Router failed, {msg}, \n {getStacktrace()}"
        except:
            handle501()
            discard
        discard
    return true

proc callback(ctx: Request) {.async.} =
    discard await handleGet(ctx)
    # let f = threadpool.spawn handleGet(ctx)
    # while not f.isReady:
    #     await sleepAsync(10)
    # discard ^f


template initSpawn(code) =
    threadpool.spawn (() => (server.initThread(); code))()

proc start*(doclear = false, port = 0, loglevel = "info") =
    let serverPort = if port == 0:
                         os.getEnv("SITE_PORT", "5050").parseInt
                     else: port
    # main Thread
    initThread()

    initCache()
    initStats()

    # Publishes new articles for one topic every x seconds
    initSpawn pubTask()

    # cleanup task for deleting low traffic articles
    initSpawn cleanupTask()


    # Configure and start server
    # let address = "0.0.0.0:" & $serverPort
    echo fmt"HTTP server listening on port {serverPort}"
    synctopics()
    var settings = initSettings(port=Port(serverPort), bindAddr="0.0.0.0")
    run(callback, settings = settings)

when isMainModule:
    # initThread()
    # let topic = "vps"
    # let page = buildHomePage("en", "")
    # page.writeHtml(SITE_PATH / "index.html")

    # initSonic()
    # let argt = getLastArticles(topic)
    # echo buildRelated(argt[0])
    # pageCache[].clear()
    start()
