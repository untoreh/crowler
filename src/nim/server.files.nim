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
       uri

{.experimental: "caseStmtMacros".}

import
    types,
    utils,
    cfg,
    quirks,
    html,
    publish,
    translate,
    rss,
    amp,
    opg,
    ldj

from publish import ut

type HtmlCache {.borrow: `.`.} = LRUTrans
proc initHtmlCache(): HtmlCache =
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    translate_db.DB_PATH = DATA_PATH / "html.db"
    result = initLRUTrans()
    openDB(result)

proc `[]`*[K: not int](c: HtmlCache, k: K): string = c[hash(k)]
proc `[]=`*[K: not int, V](c: HtmlCache, k: K, v: V) = c[hash(k)] = v

type TopicState = tuple[topdir: int, group: PyObject]
type Topics = ptr LockTable[string, TopicState]
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


proc fp(relpath: string): string =
    ## Full file path
    SITE_PATH / (if relpath == "":
        "index.html"
    elif relpath.splitFile.ext == "":
        relpath & ".html"
    else: relpath)

proc initThread*() {.gcsafe.} =
    initLogging()
    initTypes()
    initHtml()
    addLocks()
    initLDJ()
    initFeed()
    initAmp()
    initOpg()
    try:
        translate.initThread()
    except: discard

registerThreadInitializer(initThread)

template setPage(code: string): untyped {.dirty.} =
    try:
        page = htmlCache.lgetOrPut(fpath, readFile(fpath))
        dowrite = false
    except IOError:
        debug "router: file not found...generating"
        # If the lock was acquired (created) then
        # we have to build the page since no other worker did it already
        if qPages.acquireOrWait(fpath):
            debug "setpage: lock acquired, generating page {fpath}"
            defer: qPages[fpath][].release()
            page = htmlCache.put(fpath, code)
            dowrite = true
        else:
            debug "setpage: lock waited, fetching page {fpath}"
            try:
                page = htmlCache.lgetOrPut(fpath, readFile(fpath))
            except:
                # invalidate the pageLock if the file isn't present on storage
                # to force re-generation
                qPages.del(fpath)
            dowrite = false

let qPages = initPathLock()
let htmlCache = initLockTable[string, string]()

template handle301(loc: string = $WEBSITE_URL) {.dirty.} =
    # the 404 is actually a redirect
    # let body = msg
    # ctx.reply(Http404, body)
    ctx.reply(Http301, ["Location:"&loc])

template handleHomePage(relpath: string, capts: auto, ctx: HttpCtx) {.dirty.} =
    const homePath = SITE_PATH / "index.html"
    setPage:
        # in case of translations, we to generate the base page first
        # which we cache too (`setPage only caches the page that should be served)
        let (tocache, toserv) = buildHomePage(capts.lang, capts.amp)
        htmlCache[homePath] = tocache.asHtml
        toserv.asHtml
    ctx.reply(page)
    if dowrite:
        debug "homepage: writing generated file..."
        writeFile(fpath, page)

template handleAsset(fpath: string) {.dirty.} =
    setPage:
        readFile(fpath)
    ctx.reply(page)

template handleImg(fpath: string) {.dirty.} =
    setPage:
        readFile(fpath)
    ctx.reply(page)

template handleTopic(fpath, capts: auto, ctx: HttpCtx) {.dirty.} =
    debug "topic: looking for {capts.topic}"
    if capts.topic in topics:
        let topdir = topics[capts.topic].topdir
        setPage:
            let
                pagenum = if capts.page == "": "0" else: capts.page
                topic = capts.topic
            topicPage(topic, pagenum, false)
            htmlCache[SITE_PATH / capts.topic / capts.page] = pagetree.asHtml
            processPage(capts.lang, capts.amp, pagetree).asHtml
        ctx.reply(page)
        if dowrite:
            debug "topic: writing generated file..."
            writeFile(fpath, page)
    else:
        handle301($(WEBSITE_URL / capts.amp / capts.lang))

proc articlePage(donearts: PyObject, capts: auto): string =
    # every article is under a page number
    for pya in donearts[capts.page]:
        if pya.pyget("slug") == capts.art:
            let
                a = initArticle(pya, parseInt(capts.page))
                post = buildPost(a)
            htmlCache[SITE_PATH / capts.topic / capts.page / capts.art] = post.asHtml
            return processPage(capts.lang, capts.amp, post).asHtml
    return ""

template handleArticle(fpath, capts: auto, ctx: HttpCtx) =
    ##
    debug "article: fetching article"
    let tg = topics.get(capts.topic, emptyTopic)
    if tg.topdir != -1:
        setPage:
            let donearts = tg.group[$topicData.done]
            articlePage(donearts, capts)
        if page != "":
            ctx.reply(page)
            if dowrite:
                debug "article: writing generated file..."
                writeFile(fpath, page)
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
            of (topic: "img"):
                # debug "router: serving image {relpath}"
                handleImg(fpath)
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
    server.initHeaderCtx(handleGet, 5050, false)
    echo "GuildenStern HTTP server serving at 5050"
    synctopics()
    server.serve(loglevel = INFO)

# when isMainModule:
#     const useHttpBeast = true
#     # syncTopics()
#     run()
