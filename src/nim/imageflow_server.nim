import
    std/[os, monotimes, locks, uri, httpcore, strformat, hashes],
    lruCache,
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

let imgCache = initLockLruCache[string, string](32)

proc imgData(imgurl: string): Future[string] {.inline, gcsafe, async.} =
  try:
    result = imgCache.lgetOrPut(imgurl):
      await getImg(imgurl, kind=urlsrc)
  except:
    echo getCurrentException()[]
    discard

proc parseImgUrl*(relpath: string): (string, string, string) =
  let
      m = relpath.match(sre rxPathImg).get
      imgCapts = m.captures.toSeq
  let
      url = imgCapts[2].get
      width = imgCapts[0].get
      height = imgCapts[1].get
  return (url, width, height)

var
  iflThread: Thread[void]
  imgIn: LockDeque[(MonoTime, string, string, string)]
  imgOut: LockTable[(MonoTime, string, string, string), (string, string)]
  imgLock: ptr AsyncLock

proc handleImg*(relpath: string): Future[(string, string)] {.async.} =
  let (url, width, height) = parseImgUrl(relpath)
  var resp, decodedUrl, mime: string
  if url.isSomething:
    decodedUrl = url.asBString.toString(true)
    debug "img: decoded url: {decodedUrl}"
    # block unused resize requests
    if not (fmt"{width}x{height}" in IMG_SIZES):
      resp = await decodedUrl.imgData
    else:
      assert not imgIn.isnil
      let imgKey = (getMonoTime(), decodedUrl, width, height)
      imgIn.addLast imgKey
      return await imgOut.popWait(imgKey)
      debug "ifl server: img processed"
  return (resp, mime)

template submitImg(val: untyped = ("", "")) {.dirty.} = imgOut[imgKey] = val

proc processImgData(imgKey: (MonoTime, string, string, string)) {.async.} =
  # push img to imageflow context
  let (id, decodedUrl, width, height) = imgKey
  var acquired: bool
  let data = (await decodedUrl.imgData)
  if data.len == 0:
    submitImg()
    return
  try:
    await imgLock[].acquire
    acquired = true
    if not addImg(data):
      return
    let query = fmt"width={width}&height={height}&mode=max&format=webp"
    logall "ifl server: serving image hash: {hash(await decodedUrl.imgData)}, size: {width}x{height}"
    # process and send back
    submitImg:
      processImg(query)
  except CatchableError:
    submitImg()
    return
  finally:
    if acquired:
      imgLock[].release

proc asyncImgHandler() {.async.} =
  try:
    while true:
      let imgKey = await imgIn.popFirstWait
      asyncSpawn processImgData(imgKey)
  except CatchableError:
    let e = getCurrentException()[]
    warn "imageflow: image handler crashed. {e}"
    quit()

proc imgHandler*() =
  initImageFlow() # NOTE: this initializes thread vars
  waitFor asyncImgHandler()

proc startImgFlow*() =
  try:
    # start img handler thread
    setNil(imgIn):
      initLockDeque[(MonoTime, string, string, string)]()
    setNil(imgOut):
      initLockTable[(MonoTime, string, string, string), (string, string)]()
    setNil(imgLock):
      create(AsyncLock)
    reset(imgLock[])
    imgLock[] = newAsyncLock()
    createThread(iflThread, imgHandler)
  except CatchableError as e:
    warn "Could not init imageflow! \n {e[]}"
    quit()

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
