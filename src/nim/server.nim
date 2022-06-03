import strformat,
       strutils,
       tables,
       nimpy,
       std/[asyncdispatch, os, threadpool],
       os,
       times,
       locks,
       karax/vdom,
       strtabs,
       httpcore,
       guildenstern/[ctxheader, ctxbody],
       nre,
       options,
       fusion/matching,
       uri,
       lrucache,
       zippy,
       hashes,
       json

{.experimental: "caseStmtMacros".}

import
    pyutils,
    quirks,
    cfg,
    types,
    server_types,
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
    articles

const customPages* = ["dmca", "terms-of-service", "privacy-policy"]
const nobody = ""
var
    reqMime {.threadvar.}: string
    reqFile {.threadvar.}: string
    reqKey {.threadvar.}: int64

proc initThreadBase*() {.gcsafe, raises: [].} =
    initPy()
    initTypes()
    initLogging()

proc initThread*() {.gcsafe, raises: [].} =
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

template setEncoding() {.dirty.} =
    var headers: array[1, string]
    ctx.parseHeaders(["accept-encoding"], headers)
    debug "detected accepted encoding {headers}"
    if ("*" in headers[0]) or ("gzip" in headers[0]):
        hencoding.add("gzip")
        resp = resp.compress(dataFormat = dfGzip)
    elif "deflate" in headers[0]:
        hencoding.add("deflate")
        resp = resp.compress(dataFormat = dfDeflate)

proc doReply[T](ctx: HttpCtx, body: T, scode = Http200, headers: openarray[string] = @[]) {.raises: [].} =
    baseHeaders.add headers
    var resp = if likely(body != ""): body
               else:
                   sdebug "reply: body is empty!"
                   nobody
    if reqMime == "":
        reqMime = mimePath(reqFile)
    hcontent.add reqMime
    try:
        if sre("^(?:text)|(?:image)|(?:application)/") in reqMime:
            setEncoding
        debug "reply: headers -- {baseHeaders}"
        hetag.add '"' & $reqKey & '"'
    except:
        try:
            warn "reply: troubles serving page {reqFile}"
        except: discard
    sdebug "reply: sending: {len(resp)}"
    ctx.reply(scode, resp, baseHeaders)
    sdebug "reply: sent: {len(resp)}"

template handle301*(loc: string = $WEBSITE_URL) {.dirty.} =
    ctx.doReply(nobody, scode = Http301, headers = ["Location:"&loc])

template handle404*(body: var string) =
    ctx.doReply(body, scode = Http404, headers = ["Location:"&loc])

template handleHomePage(relpath: string, capts: auto, ctx: HttpCtx) {.dirty.} =
    const homePath = SITE_PATH / "index.html"
    page = pageCache[].lcheckOrPut(reqKey):
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = buildHomePage(capts.lang, capts.amp)
        pageCache[homePath] = tocache.asHtml
        toserv.asHtml
    ctx.doReply(page)

template handleAsset() {.dirty.} =
    when releaseMode:
        try:
            page = pageCache[].get(reqKey)
        except KeyError:
            page = readFile(reqFile)
            if page != "":
                pageCache[reqKey] = page
    else:
        debug "ASSETS CACHING DISABLED"
        reqMime = mimePath(reqFile)
        page = readFile(reqFile)
    ctx.doReply(page)

template dispatchImg(relpath: var string, ctx: auto) {.dirty.} =
    var mime: string
    try:
        relpath.removePrefix("/i")
        (mime, page) = pageCache[].get(relpath).split(";", maxsplit = 1)
    except KeyError, AssertionDefect:
        try: (page, mime) = handleImg(relpath)
        except: debug "server: could not handle image {relpath}"
        if likely(page != ""):
            # append the mimetype before the img data
            pageCache[][relpath] = mime & ";" & page
    hcontent.add(mime)
    ctx.doReply(page)

template handleTopic(capts: auto, ctx: HttpCtx) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topicsCache:
        page = pageCache[].lcheckOrPut(reqKey):
            let
                pagenum = if capts.page == "": "0" else: capts.page
                topic = capts.topic
            topicPage(topic, pagenum, false)
            pageCache[SITE_PATH / capts.topic / capts.page] = pagetree.asHtml
            processPage(capts.lang, capts.amp, pagetree).asHtml
        ctx.doReply(page)
    elif capts.topic in customPages:
        debug "WOWOWO"
        page = pageCache[].lcheckOrPut(reqKey):
            pageFromTemplate(capts.topic, capts.lang, capts.amp)
        ctx.doReply(page)
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleArticle(capts: auto, ctx: HttpCtx) =
    ##
    debug "article: fetching article"
    let tg = topicsCache.get(capts.topic, emptyTopic)
    if tg.topdir != -1:
        page = pageCache[].lcheckOrPut(reqKey):
            debug "article: generating article"
            articleHtml(capts)
        if page != "":
            ctx.doReply(page)
        else:
            debug "article: redirecting to topic because page is empty"
            handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleSearch(relpath: string, ctx: HttpCtx) =
    # extract the referer to get the correct language
    var headers: array[1, string]
    ctx.parseHeaders(["referer"], headers)
    let
        refuri = parseUri(headers[0])
        refcapts = refuri.path.uriTuple
    if capts.lang == "" and refcapts.lang != "":
        handle301($(WEBSITE_URL / refcapts.lang / join(capts, n = 1)))
    else:
        page = pageCache[].lcheckOrPut(reqKey):
            # there is no specialized capture for the query
            let
                searchq = something(parseUri(capts.art).query.getParam("q"), capts.art)
                lang = something(capts.lang, refcapts.lang)
            buildSearchPage(capts.topic, searchq, lang).asHtml
        ctx.doReply(page)

template handleSuggest(relpath: string, ctx: HttpCtx) =
    # there is no specialized capture for the query
    let searchq = something(parseUri(capts.art).query.getParam("q"), capts.art)
    page = buildSuggestList(capts.topic, searchq)
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

proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    doassert ctx.parseRequestLine
    reset(reqMime)
    reset(reqFile)
    reset(reqKey)
    resetHeaders()
    var
        relpath = ctx.getUri()
        page: string
        headers: seq[string]
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
            ctx.doReply("", scode = Http501)
            discard
        discard

proc pubTask*() {.gcsafe.} =
    initThread()
    syncTopics()
    # Give some time to services to warm up
    sleep(10000)
    let t = getTime()
    # Only publish one topic every `CRON_TOPIC`
    while true:
        let topic = nextTopic()
        # Don't publish each topic more than `CRON_TOPIC_FREQ`
        if inHours(t - topicPubdate()) > cfg.CRON_TOPIC_FREQ:
            pubTopic(topic)
        sleep(cfg.CRON_TOPIC * 1000)

let broker = relPyImport("proxies_pb")
const proxySyncInterval = 60 * 1000
proc proxyTask() {.gcsafe.} =
    initThread()
    # syncTopics()
    let syfp = broker.getAttr("sync_from_file")
    while true:
        withPyLock:
            discard syfp()
        sleep(proxySyncInterval)

proc start*(doclear = false, port = 5050) =
    var server = new GuildenServer
    # main Thread
    initThread()
    # cache is global
    initCache()

    # Publishes new articles for one topic every x seconds
    spawn pubTask()

    # (python) Task for syncing proxy list
    spawn proxyTask()

    # Clear database before serving
    if doclear:
        if os.getenv("DO_SERVER_CLEAR", "") == "1":
            echo fmt"Clearing pageCache at {pageCache[].path}"
            pageCache[].clear()
        else:
            echo "Ignoring doclear flag because 'DO_SERVER_CLEAR' env var is not set to '1'."

    # Configure and start server
    registerThreadInitializer(initThread)
    server.initHeaderCtx(handleGet, port, false)
    echo fmt"HTTP server listening on port {port}"
    synctopics()
    server.serve(loglevel = INFO)

when isMainModule:
    pageCache[].clear()
    start()
