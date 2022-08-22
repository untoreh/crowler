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
var imgOut*: LockTable[(string, string, string), (string, string)]
var imgEvent*: ptr AsyncEvent
var imgLock*: ptr AsyncLock

proc handleImg*(relpath: string): Future[(string, string)] {.async.} =
  let (url, width, height) = parseImgUrl(relpath)
  var respMime: (string, string)
  var resp, decodedUrl, mime: string
  if url.isSomething:
    decodedUrl = url.asBString.toString(true)
    debug "img: decoded url: {decodedUrl}"
    # block unused resize requests
    if not (fmt"{width}x{height}" in IMG_SIZES):
      resp = await decodedUrl.imgData
    else:
      assert not imgIn.isnil
      let imgKey = (decodedUrl, width, height)
      await imgIn[].put(imgKey)
      while true:
        await wait(imgEvent[])
        if imgKey in imgOut:
          doassert imgOut.pop(imgKey, respMime)
          return respMime
          debug "ifl server: img processed"
  return (resp, mime)

template submitImg(val: untyped = ("", "")) {.dirty.} =
  imgOut[imgKey] = val
  imgEvent[].fire; imgEvent[].clear

proc processImgData(imgKey: (string, string, string)) {.async.} =
  # push img to imageflow context
  let (decodedUrl, width, height) = imgKey
  let data = (await decodedUrl.imgData)
  if data.len == 0:
    submitImg()
    return
  try:

    await imgLock[].acquire
    if not addImg(data):
      return
    let query = fmt"width={width}&height={height}&mode=max&format=webp"
    logall "ifl server: serving image hash: {hash(await decodedUrl.imgData)}, size: {width}x{height}"
    # process and send back
    submitImg:
      processImg(query)
  except CatchableError:
    submitImg()
  finally:
    imgLock[].release


proc asyncImgHandler() {.async.} =
  try:
    while true:
      let imgKey = await imgIn[].get()
      asyncSpawn processImgData(imgKey)
  except:
    discard

proc imgHandler*() = waitFor asyncImgHandler()

proc startImgFlow*() =
  try:
    initImageFlow()
    # start img handler thread
    imgIn = create(AsyncQueue[(string, string, string)])
    imgIn[] = newAsyncQueue[(string, string, string)](64)
    imgOut = initLockTable[(string, string, string), (string, string)]()
    imgEvent = create(AsyncEvent)
    imgEvent[] = newAsyncEvent()
    imgLock = create(AsyncLock)
    imgLock[] = newAsyncLock()
    createThread(iflThread, imgHandler)
  except CatchableError as e:
    warn "Could not init imageflow! \n {e[]}"

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
#         let msg = getCurrentException()[]
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
