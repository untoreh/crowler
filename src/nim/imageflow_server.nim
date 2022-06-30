import
       httpcore,
       nre,
       uri,
       os,
       lruCache,
       httpclient,
       strformat,
       hashes

import
    cfg,
    types,
    imageflow,
    utils,
    locktpl,
    shorturls

const rxPathImg = "/([0-9]{1,3})x([0-9]{1,3})/\\?(.+)(?=/|$)"

let
    imgCache = initLockLruCache[string, string](10 * 1024)
    flwCache = initLockLruCache[string, string](30 * 1024)

proc initWrapImageFlow*() {.gcsafe, raises: [].} =
    try: initImageFlow()
    except:
        qdebug "Could not init imageflow"

proc imgData(imgurl: string): string {.inline, gcsafe.} =
    try:
        result = imgCache.lgetOrPut(imgurl):
            getImg(imgurl, kind=urlsrc)
    except: discard

proc parseImgUrl*(relpath: string): (string, string, string) =
    let
        m = relpath.match(sre rxPathImg).get
        imgCapts = m.captures.toSeq
    let
        url = imgCapts[2].get
        width = imgCapts[0].get
        height = imgCapts[1].get
    return (url, width, height)


proc handleImg*(relpath: string): auto =
    let (url, width, height) = parseImgUrl(relpath)
    var resp, decodedUrl, mime: string
    if url.isSomething:
        decodedUrl = url.asBString.toString(true)
        # block unused resize requests
        if not (fmt"{width}x{height}" in IMG_SIZES):
            resp = decodedUrl.imgData
        else:
            doassert decodedUrl.imgData.addImg
            let query = fmt"width={width}&height={height}&mode=max"
            debug "ifl server: serving image hash: {hash(decodedUrl.imgData)}, size: {width}x{height}"
            (resp, mime) = processImg(query)
        debug "ifl server: img processed"
    (resp, mime)

# import guildenstern/ctxheader
# proc handleGet(ctx: HttpCtx) {.gcsafe, raises: [].} =
#     assert ctx.parseRequestLine
#     var relpath = ctx.getUri()
#     # relpath.removePrefix('/')
#     try:
#         let (resp, _) = handleImg(relpath)
#         if resp.isSomething:
#             ctx.reply(resp)
#         else:
#             debug "ifl server: bad url"
#             ctx.reply(Http404)
#     except:
#         let msg = getCurrentExceptionMsg()
#         ctx.reply(Http501)
#         qdebug "Router failed, {msg}"
#         discard


# when isMainModule:
#     var srv = new GuildenServer
#     registerThreadInitializer(initThreadBase)
#     registerThreadInitializer(initWrapImageFlow)
#     srv.initHeaderCtx(handleGet, 5051, false)
#     echo "GuildenStern HTTP server serving at 5050"
#     srv.serve(loglevel = INFO)
