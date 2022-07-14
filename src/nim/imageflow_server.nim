import
       httpcore,
       nre,
       uri,
       os,
       lruCache,
       httpclient,
       strformat,
       hashes,
       chronos,
       chronos/asyncloop

import
    cfg,
    types,
    imageflow,
    utils,
    locktpl,
    shorturls

const rxPathImg = "/([0-9]{1,3})x([0-9]{1,3})/\\?(.+)(?=/|$)"

let imgCache = initLockLruCache[string, string](1024)

proc initWrapImageFlow*() {.gcsafe, raises: [].} =
    try: initImageFlow()
    except:
        qdebug "Could not init imageflow"

proc imgData(imgurl: string): Future[string] {.inline, gcsafe, async.} =
    try:
        result = imgCache.lgetOrPut(imgurl):
            await getImg(imgurl, kind=urlsrc)
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

var iflThread: Thread[void]
var imgIn*: ptr AsyncQueue[(string, string, string)]
var imgOut*: LockTable[string, (string, string)]
var imgEvent*: ptr AsyncEvent

proc handleImg*(relpath: string): Future[(string, string)] {.async.} =
    let (url, width, height) = parseImgUrl(relpath)
    var respMime: (string, string)
    var resp, decodedUrl, mime: string
    if url.isSomething:
        decodedUrl = url.asBString.toString(true)
        # block unused resize requests
        if not (fmt"{width}x{height}" in IMG_SIZES):
            resp = await decodedUrl.imgData
        else:
            assert not imgIn.isnil
            await imgIn[].put((decodedUrl, width, height))
            while true:
                await wait(imgEvent[])
                if decodedUrl in imgOut:
                    doassert imgOut.pop(decodedUrl, respMime)
                    return respMime
        debug "ifl server: img processed"
    return (resp, mime)

proc processImgData(decodedUrl: string, width: string, height: string) {.async.} =
    # push img to imageflow context
    doassert (await decodedUrl.imgData).addImg
    let query = fmt"width={width}&height={height}&mode=max"
    logall "ifl server: serving image hash: {hash(await decodedUrl.imgData)}, size: {width}x{height}"
    # process and send back
    imgOut[decodedUrl] = processImg(query)
    imgEvent[].fire; imgEvent[].clear

proc asyncImgHandler() {.async.} =
    while true:
        let (decodedUrl, width, height) = await imgIn[].get()
        asyncSpawn processImgData(decodedUrl, width, height)

proc imgHandler*() = waitFor asyncImgHandler()

proc startImgFlow*() =
    initImageFlow()
    # start img handler thread
    imgIn = create(AsyncQueue[(string, string, string)])
    imgIn[] = newAsyncQueue[(string, string, string)](64)
    imgOut = initLockTable[string, (string, string)]()
    imgEvent = create(AsyncEvent)
    imgEvent[] = newAsyncEvent()
    createThread(iflThread, imgHandler)
# import chronos
# var iflThread: Thread[(string, string)]
# createThread()
# proc iflHandler*() =



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
