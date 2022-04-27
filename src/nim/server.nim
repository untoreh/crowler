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
       hashes

{.experimental: "caseStmtMacros".}

import
    types,
    utils,
    cfg,
    quirks,
    html,
    publish,
    translate,
    translate_db,
    rss,
    amp,
    opg,
    ldj,
    imageflow_server

from publish import ut

type HtmlCache {.borrow: `.`.} = LRUTrans
var htmlCache: ptr HtmlCache
proc initHtmlCache(): HtmlCache =
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    translate_db.DB_PATH = DATA_PATH / "html.db"
    result = initLRUTrans()
    openDB(result)

# proc `[]`*[K: not int](c: HtmlCache, k: K): string {.inline.} = c[hash(k)]
# proc `[]=`*[K: not int, V](c: HtmlCache, k: K, v: V) {.inline.} = c[hash(k)] = v
proc `[]`*[K: not int](c: ptr HtmlCache, k: K): string {.inline.} =
    c[][hash(k)]
proc `[]=`*[K: not int, V](c: ptr HtmlCache, k: K, v: V) {.inline.} =
    c[][hash(k)] = v

type
    TopicState = tuple[topdir: int, group: PyObject]
    Topics = ptr LockTable[string, TopicState]
let
    topics = create LockTable[string, TopicState]
    emptyTopic = (topdir: -1, group: PyObject())
topics[] = initLockTable[string, TopicState]()
proc len(t: Topics): int = t[].len
proc `[]=`(t: Topics, k, v: auto) = t[][k] = v
proc `[]`(t: Topics, k: string): TopicState = t[][k]
proc contains(t: Topics, k: string): bool = k in t[]
proc get(t: Topics, k: string, d: TopicState): TopicState = t[].get(k, d)

const customPages = ["dmca", "tos", "privacy-policy"]

proc syncTopics() {.gcsafe.} =
    # NOTE: the [0] is required because quirky zarray `getitem`
    try:
        let
            pytopics = initPySequence[string](ut.load_topics()[0])
            n_topics = pytopics.len

        if n_topics > topics.len:
            for topic in pytopics.slice(topics.len, pytopics.len):
                let
                    tp = topic.to(string)
                    tg = ut.topic_group(tp)
                    td = tp.getState[0]
                debug "synctopics: adding topic {tp} to global"
                topics[tp] = (topdir: td, group: tg)
    except Exception as e:
        debug "could not sync topics {getCurrentExceptionMsg()}"


proc fp*(relpath: string): string =
    ## Full file path
    SITE_PATH / (if relpath == "":
        "index.html"
    elif relpath.splitFile.ext == "":
        relpath & ".html"
    else: relpath)

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
    ctx.reply(page)

template dispatchImg(relpath: var string, ctx: auto) {.dirty.} =
    try:
        page = htmlCache[].get(relpath)
    except KeyError:
        relpath.removePrefix("/i")
        page = handleImg(relpath)
        if page != "":
            htmlCache[relpath] = page
    ctx.reply(page)

template handleTopic(fpath, capts: auto, ctx: HttpCtx) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topics:
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

proc articlePage(donearts: PyObject, capts: auto): string {.gcsafe.} =
    # every article is under a page number
    for pya in donearts[capts.page]:
        if pya.pyget("slug") == capts.art:
            let
                a = initArticle(pya, parseInt(capts.page))
                post = buildPost(a)
            # htmlCache[SITE_PATH / capts.topic / capts.page / capts.art] = post.asHtml
            return processPage(capts.lang, capts.amp, post).asHtml
    return ""

template handleArticle(fpath, capts: auto, ctx: HttpCtx) =
    ##
    debug "article: fetching article"
    let tg = topics.get(capts.topic, emptyTopic)
    if tg.topdir != -1:
        page = htmlCache[].lgetOrPut(fpath):
            let donearts = tg.group[$topicData.done]
            articlePage(donearts, capts)
        if page != "":
            ctx.reply(page)
        else:
            handle301($(WEBSITE_URL / capts.amp / capts.lang / capts.topic))
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

const
    rxend = "(?=/|$)"
    rxAmp = fmt"(/amp{rxend})"
    rxLang = "(/[a-z]{2}(?:-[A-Z]{2})?" & fmt"{rxend})" # split to avoid formatting regex `{}` usage
    rxTopic = fmt"(/.*?{rxend})"
    rxPage = fmt"(/[0-9]+{rxend})"
    rxArt = fmt"(/.*?{rxend})"
    rxPath = fmt"{rxAmp}?{rxLang}?{rxTopic}?{rxPage}?{rxArt}?"

proc uriTuple(match: seq[Option[string]]): tuple[amp, lang, topic, page, art: string] =
    var i = 0
    for v in result.fields:
        v = match[i].get("")
        v.removePrefix("/")
        i += 1


proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    assert ctx.parseRequestLine
    var
        relpath = ctx.getUri()
        page: string
        dowrite: bool
    relpath.removeSuffix('/')
    let fpath = relpath.fp
    try:
        let
            m = relpath.match(sre rxPath).get
            capts = m.captures.toSeq.uriTuple
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
