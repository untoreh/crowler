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
    translate

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

var pageCache = initTable[string, string]()

proc fetchPage(path: string): string =
    try:
        pageCache[path]
    except KeyError:
        let filepath = SITE_PATH / path
        if os.fileExists(filepath):
            pageCache[path] = readFile(filepath)
        pageCache[path]

proc fp(relpath: string): string = SITE_PATH / relpath & ".html"

proc writeFileAsync(path: string, content: auto) {.async.} =
    let dir = path.parentDir
    if not dir.dirExists:
        createDir(dir)
    var file = openAsync(path, fmReadWrite)
    let prom = file.write(content)
    defer:
        await prom
        file.close()

template getOrLPut(c, k, v: untyped): untyped =
    ## Lazy `mgetOrPut`
    try:
        c[k]
    except KeyError:
        c[k] = v
        c[k]

template setPage(code: untyped): untyped {.dirty.} =
    try:
        page = readFile(fpath)
    except:
        # If we waited, another worker generated the page
        # so read reading from disk
        if qPages.waitOrAcquire(fpath):
            page = readFile(fpath)
        # If the lock was acquired (created) then
        # we have to build the page since no other worker did it already
        else:
            page = code
            debug "writing to file {fpath}"
            waitFor writeFileAsync(fpath, page)

let qPages = initPathLock()
let htmlCache = initLockTable[string, tuple[tree: VNode, str: string]]()

template handleHomePage(path: string, capts: auto, ctx: HttpCtx) {.dirty.} =
    var page: string
    setPage:
        htmlCache.getOrLPut(
            path,
            buildHomePage(
                capts.lang,
                capts.amp == "")).str
                                    # of TLangsCodes:
    #     handlePage:
    #         block:
    #             let
    #                 path = SITE_PATH
    #                 code = page
    #                 fullpath = path / code / "index.html"
    #                 data = htmlCache.getOrLPut(page, buildHomePage())
    #             # setupTranslation()
    #             # translateTree(data, fullpath, rx_file, langpairs)
    #             buildHomePage().asHtml
    #     discard
        # if page in topics:
        #     discard
            # handlePage

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
        v.removeSuffix("")
        i += 1

proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    assert ctx.parseRequestLine
    var relpath = ctx.getUri
    relpath.removeSuffix('/')
    let fpath = relpath.fp
    try:
        let
            m = relpath.match(sre rxPath).get
            capts = m.captures.toSeq.uriTuple
        case capts:
            of (topic: ""):
                debug "router: serving homepage {relpath}"
                handleHomePage(relpath, capts, ctx)
            of (art: == ""):
                # topic page
                let p = "topic"
                ctx.reply(p)
            else:
                # article page
                let p = "article"
                ctx.reply(p)
    except:
        try:
            let msg = getCurrentException().msg
            debug "Router failed, {msg}"
        except:
            discard
        discard

var server = new GuildenServer
server.initHeaderCtx(handleGet, 5050, false)
echo "GuildenStern HTTP server serving at 5050"
server.serve(loglevel = DEBUG)

# when isMainModule:
#     const useHttpBeast = true
#     # syncTopics()
#     run()
