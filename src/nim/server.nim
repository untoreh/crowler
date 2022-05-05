import strformat,
       strutils,
       tables,
       nimpy,
       std/[asyncfile, asyncdispatch, os, enumerate, with],
       weave,
       locks,
       karax/vdom,
       cgi, strtabs,
       httpcore,
       guildenstern/[ctxheader, ctxbody],
       nre,
       options,
       fusion/matching,
       uri,
       lrucache,
       hashes,
       json

{.experimental: "caseStmtMacros".}

import
    types,
    server_types,
    utils,
    cfg,
    quirks,
    html,
    html_misc,
    publish,
    translate,
    translate_db,
    rss,
    amp,
    opg,
    ldj,
    imageflow_server,
    cache,
    topics,
    search

# proc `[]`*[K: not int](c: HtmlCache, k: K): string {.inline.} = c[hash(k)]
# proc `[]=`*[K: not int, V](c: HtmlCache, k: K, v: V) {.inline.} = c[hash(k)] = v
# proc `[]`*[K](c: ptr HtmlCache, k: K): string {.inline.} =
#     debug "accessing {k}, {hash(k)}"
#     c[][k]

const customPages = ["dmca", "tos", "privacy-policy"]

proc initThreadBase*() {.gcsafe, raises: [].} =
    initLogging()
    initTypes()

proc initThread*() {.gcsafe, raises: [].} =
    initThreadBase()
    initHtml()
    addLocks()
    initLDJ()
    initFeed()
    initWrapImageFlow()
    initSonic()
    try:
        initAmp()
    except:
        qdebug "server: failed to initAmp"
    initOpg()
    try:
        translate.initThread()
    except:
        qdebug "failed to init translate"



template handle301*(loc: string = $WEBSITE_URL) {.dirty.} =
    # the 404 is actually a redirect
    # let body = msg
    # ctx.reply(Http404, body)
    ctx.reply(Http301, ["Location:"&loc])

template handleHomePage(relpath: string, capts: auto, ctx: HttpCtx) {.dirty.} =
    const homePath = SITE_PATH / "index.html"
    page = htmlCache[].lgetOrPut(fpath):
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = buildHomePage(capts.lang, capts.amp)
        htmlCache[homePath] = tocache.asHtml
        toserv.asHtml
    ctx.reply(page)

template handleAsset(fpath: string) {.dirty.} =
    try:
        page = htmlCache[].get(fpath)
    except KeyError:
        page = readFile(fpath)
        if page != "":
            htmlCache[fpath] = page
    # debug "ASSETS CACHING DISABLED"
    # page = readFile(fpath)
    ctx.reply(Http200, page, ["Cache-Control", "no-store"])

template dispatchImg(relpath: var string, ctx: auto) {.dirty.} =
    try:
        relpath.removePrefix("/i")
        page = htmlCache[].get(relpath)
    except KeyError, AssertionError:
        try: page = handleImg(relpath)
        except: debug "server: could not handle image {relpath}"
        if page != "":
            htmlCache[][relpath] = page
    ctx.reply(page)

template handleTopic(fpath, capts: auto, ctx: HttpCtx) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topicsCache:
        page = htmlCache[].lgetOrPut(fpath):
            let
                pagenum = if capts.page == "": "0" else: capts.page
                topic = capts.topic
            topicPage(topic, pagenum, false)
            htmlCache[SITE_PATH / capts.topic / capts.page] = pagetree.asHtml
            processPage(capts.lang, capts.amp, pagetree).asHtml
        ctx.reply(page)
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

template handleArticle(fpath, capts: auto, ctx: HttpCtx) =
    ##
    debug "article: fetching article"
    let tg = topicsCache.get(capts.topic, emptyTopic)
    if tg.topdir != -1:
        page = htmlCache[].lgetOrPut(fpath):
            let donearts = tg.group[$topicData.done]
            articleHtml(donearts, capts)
        if page != "":
            ctx.reply(page)
        else:
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
        handle301($(WEBSITE_URL / refcapts.lang / join(capts, n=1)))
    else:
        page = htmlCache[].lgetOrPut(fpath):
            # there is no specialized capture for the query
            let
                searchq = something(parseUri(capts.art).query.getParam("q"), capts.art)
                lang = something(capts.lang, refcapts.lang)
            buildSearchPage(capts.topic, searchq, lang)
        ctx.reply(page)

template handleSuggest(relpath: string, ctx: HttpCtx) =
    # there is no specialized capture for the query
    let searchq = something(parseUri(capts.art).query.getParam("q"), capts.art)
    page = buildSuggestList(capts.topic, searchq)
    ctx.reply(page)

proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    doassert ctx.parseRequestLine
    var
        relpath = ctx.getUri()
        page: string
    relpath.removeSuffix('/')
    let fpath = relpath.fp
    try:
        let capts = uriTuple(relpath)
        case capts:
            of (topic: ""):
                debug "router: serving homepage rel: {relpath}, fp: {fpath}"
                handleHomePage(relpath, capts, ctx)
            of (topic: "assets"):
                # debug "router: serving assets {relpath}"
                handleAsset(fpath)
            of (topic: "i"):
                # debug "router: serving image {relpath}"
                dispatchImg(relpath, ctx)
            of (page: "s"):
                debug "router: serving search {relpath}"
                handleSearch(relpath, ctx)
            of (page: "g"):
                debug "router: serving suggestion {relpath}"
                handleSuggest(relpath, ctx)
            of (art: ""):
                debug "router: serving topic {relpath}"
                # topic page
                handleTopic(fpath, capts, ctx)
            else:
                debug "router: serving article {relpath}, {capts}"
                # article page
                handleArticle(fpath, capts, ctx)
    except:
        try:
            let msg = getCurrentExceptionMsg()
            handle301()
            debug "Router failed, {msg}"
        except:
            ctx.reply(Http501)
            discard
        discard

when isMainModule:

    var server = new GuildenServer
    let hc = initHtmlCache()
    htmlCache = hc.unsafeAddr
    htmlCache[].clear()
    registerThreadInitializer(initThread)
    server.initHeaderCtx(handleGet, 5050, false)

    echo "GuildenStern HTTP server serving at 5050"
    synctopics()
    server.serve(loglevel = INFO)
