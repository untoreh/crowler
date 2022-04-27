import
       httpcore,
       guildenstern/[ctxheader, ctxbody],
       strutils,
       nre,
       json,
       uri,
       os,
       std/tempfiles,
       std/exitprocs,
       lruCache,
       httpclient,
       strformat,
       hashes

import
    cfg,
    types,
    imageflow,
    utils,
    server,
    locktpl,
    shorturls

lockedStore(LruCache)

const rxPathImg = "/([0-9]{1,3})x([0-9]{1,3})/(.+)(?=/|$)"

let
    imgCache = initLockLruCache[string, string](10 * 1024)
    flwCache = initLockLruCache[string, string](30 * 1024)

proc imgData(imgurl: string): string {.inline, gcsafe.} =
    imgCache.lgetOrPut(imgurl):
        getImg(imgurl, kind=urlsrc)

proc handleImg*(relpath: string): auto =
    let
        m = relpath.match(sre rxPathImg).get
        imgCapts = m.captures.toSeq
    let
        url = imgCapts[2].get
        width = imgCapts[0].get
        height = imgCapts[1].get

    var resp: string
    if url.isSomething:
        let decodedUrl = url.asBString.toString
        doassert decodedUrl.imgData.addImg
        let query = fmt"width={width}&height={height}&mode=max"
        debug "ifl server: serving image rel: {decodedUrl}, size: {width}x{height}"
        resp = processImg(query)
        debug "ifl server: img processed"
    resp

proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
    assert ctx.parseRequestLine
    var
        relpath = ctx.getUri()
        page: string
        dowrite: bool
    # relpath.removePrefix('/')
    try:
        let resp = handleImg(relpath)
        if resp.isSomething:
            ctx.reply(resp)
        else:
            debug "ifl server: bad url"
            ctx.reply(Http404)
    except:
        let msg = getCurrentExceptionMsg()
        ctx.reply(Http501)
        qdebug "Router failed, {msg}"
        discard

proc initWrapImageFlow*() {.gcsafe, raises: [].} =
    try: initImageFlow()
    except:
        qdebug "Could not init imageflow"

when isMainModule:
    var srv = new GuildenServer
    registerThreadInitializer(initThreadBase)
    registerThreadInitializer(initWrapImageFlow)
    srv.initHeaderCtx(handleGet, 5051, false)
    echo "GuildenStern HTTP server serving at 5050"
    srv.serve(loglevel = INFO)
