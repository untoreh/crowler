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
       fusion/matching

{.experimental: "caseStmtMacros".}

import
    types,
    utils,
    cfg,
    quirks,
    html,
    pages,
    translate,
    rss,
    amp,
    opg,
    ldj

from publish import ut

var topics {.threadvar.}: Table[string, PyObject]
const customPages = ["dmca", "tos", "privacy-policy"]

proc syncTopics() =
    # NOTE: the [0] is required because quirky zarray `getitem`
    let
        pytopics = initPySequence[string](ut.load_topics()[0])
        n_topics = pytopics.len

    if n_topics > topics.len:
        for topic in pytopics.slice(topics.len, -1):
            let tp = topic.to(string)
            topics[tp] = ut.topic_group(tp)

proc fp(relpath: string): string =
    ## Full file path
    SITE_PATH / (if relpath == "":
        "index.html"
    elif relpath.splitFile.ext == "":
        relpath & ".html"
    else: relpath)

proc writeFileAsync(relpath: string, content: auto) {.async.} =
    let dir = relpath.parentDir
    if not dir.dirExists:
        createDir(dir)
    var file = openAsync(relpath, fmReadWrite)
    let prom = file.write(content)
    await prom
    file.close()

proc initThread*() {.gcsafe.} =
    initLogging()
    initTypes()
    initHtml()
    addLocks()
    initLDJ()
    initFeed()
    initAmp()
    initOpg()

registerThreadInitializer(initThread)

template setPage(code: string): untyped {.dirty.} =
    try:
        page = htmlCache.lgetOrPut(fpath, readFile(fpath))
        dowrite = false
    except:
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
            page = htmlCache.lgetOrPut(fpath, readFile(fpath))
            dowrite = false

let qPages = initPathLock()
let htmlCache = initLockTable[string, string]()

template handleHomePage(relpath: string, capts: auto, ctx: HttpCtx) {.dirty.} =
    # case capts:
    #     (lang: == "", amp: == "")
    setPage:
        buildHomePage(capts.lang, capts.amp != "")[0].asHtml
    ctx.reply(page)
    if dowrite:
        debug "homepage: writing generated file..."
        writeFile(fpath, page)
        # of TLangsCodes:
    #     handlePage:
    #         block:
    #             let
    #                 relpath = SITE_PATH
    #                 code = page
    #                 fullpath = relpath / code / "index.html"
    #                 data = htmlCache.lgetOrPut(page, buildHomePage())
    #             # setupTranslation()
    #             # translateTree(data, fullpath, rx_file, langpairs)
    #             buildHomePage().asHtml
    #     discard
        # if page in topics:
        #     discard
            # handlePage

template handleAsset(fpath: string) {.dirty.} =
    setPage:
        readFile(fpath)
    ctx.reply(page)

proc srvTopicPage(topic, pagenum = ""): auto = fmt"topic page number {pagenum}"
proc srvTopicArticle(topic, pagenum, slug: string): auto = fmt"article page named {slug}"

const
    rxend = "(?=/|$)"
    rxAmp = fmt"(/amp{rxend})"
    rxLang = "(/[a-z]{2}(?:-[A-Z]{2})?" & fmt"{rxend})" # split to avoid formatting regex `{}` usage
    rxTopic = fmt"(/.*?{rxend})"
    rxArt = fmt"(/.*?{rxend})"
    rxPath = fmt"{rxAmp}?{rxLang}?{rxTopic}?{rxArt}?"

proc uriTuple(match: seq[Option[string]]): tuple[amp, lang, topic, art: string] =
    var i = 0
    for v in result.fields:
        v = match[i].get("")
        v.removePrefix("/")
        i += 1

import uri

proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    assert ctx.parseRequestLine
    var
        relpath = ctx.getUri
        page: string
        dowrite: bool
    relpath.removeSuffix('/')
    let fpath = relpath.fp
    try:
        let
            m = relpath.match(sre rxPath).get
            capts = m.captures.toSeq.uriTuple
        echo capts
        case capts:
            of (topic: ""):
                debug "router: serving homepage rel: {relpath}, fp: {fpath}"
                handleHomePage(relpath, capts, ctx)
            of (topic: "assets"):
                debug "router: serving assets"
                handleAsset(fpath)
            of (art: ""):
                debug "router: serving topic {relpath}"
                # topic page
                let p = "topic"
                ctx.reply(p)
            else:
                debug "router: serving article {relpath}, {capts}"
                # article page
                let p = "article"
                ctx.reply(p)
    except:
        try:
            let msg = getCurrentException().msg
            let r = asHtml("Not found!")
            ctx.reply(Http400, r)
            debug "Router failed, {msg}"
        except:
            ctx.reply(Http501)
            discard
        discard

when isMainModule:
    var server = new GuildenServer
    server.initHeaderCtx(handleGet, 5050, false)
    echo "GuildenStern HTTP server serving at 5050"
    server.serve(loglevel = INFO)

# when isMainModule:
#     const useHttpBeast = true
#     # syncTopics()
#     run()
