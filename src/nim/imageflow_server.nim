import
    std/[os, monotimes, locks, uri, httpcore, strformat, hashes],
    lruCache,
    chronos

import
    cfg,
    types,
    imageflow,
    utils,
    locktpl,
    shorturls


type
  ImgQuery = object
    id: MonoTime
    url, width, height: string
  ImgData = object
    mime, data: ptr string

proc free*(o: ptr ImgData) =
  if not o.isnil:
    reset(o.mime[])
    dealloc(o.mime)
    reset(o.data[])
    dealloc(o.data)
    dealloc(o)

proc newImgData(): ptr Imgdata =
  result = create(ImgData)
  result.mime = create(string)
  result.data = create(string)

const rxPathImg = "/([0-9]{1,3})x([0-9]{1,3})/\\?(.+)(?=/|$)"

let imgCache = initLockLruCache[string, string](32)

proc imgData(imgurl: string): Future[string] {.inline, gcsafe, async.} =
  try:
    result = imgCache.lgetOrPut(imgurl):
      await getImg(imgurl, kind=urlsrc)
  except:
    echo getCurrentException()[]
    discard

proc parseImgUrl*(relpath: string): ImgQuery =
  let
      m = relpath.match(sre rxPathImg).get
      imgCapts = m.captures.toSeq
  result.id = getMonoTime()
  result.url = imgCapts[2].get
  result.width = imgCapts[0].get
  result.height = imgCapts[1].get

var
  iflThread: Thread[void]
  imgIn: AsyncPColl[ptr ImgQuery]
  imgOut: AsyncTable[ptr ImgQuery, ptr ImgData]
  imgLock: ptr AsyncLock

proc handleImg*(relpath: string): Future[(string, string)] {.async.} =
  var q = parseImgUrl(relpath)
  if q.url.isSomething:
    var decodedUrl = q.url.asBString.toString(true)
    debug "img: decoded url: {decodedUrl}"
    # block unused resize requests
    if not (fmt"{q.width}x{q.height}" in IMG_SIZES):
      result[0] = await decodedUrl.imgData
    else:
      q.url = decodedUrl
      imgIn.add q.addr
      let resp = await imgOut.pop(q.addr)
      if not resp.isnil:
        defer: free(resp)
        result = (resp.data[], resp.mime[])
      debug "ifl server: img processed"

template submitImg(val: untyped = nil) {.dirty.} = imgOut[q] = val

proc processImgData(q: ptr ImgQuery) {.async.} =
  # push img to imageflow context
  initImageFlow() # NOTE: this initializes thread vars
  var acquired, submitted: bool
  let data = (await q.url.imgData)
  let res = newImgData()
  defer:
    if acquired: imgLock[].release
    if not submitted:
      imgOut[q] = res
  if data.len > 0:
    try:
      await imgLock[].acquire
      acquired = true
      if addImg(data):
        let query = fmt"width={q.width}&height={q.height}&mode=max&format=webp"
        logall "ifl server: serving image hash: {hash(await q.url.imgData)}, size: {q.width}x{q.height}"
        # process and send back
        (res.data[], res.mime[]) = processImg(query)
        imgOut[q] = res
        submitted = true
    except CatchableError:
      discard

proc asyncImgHandler() {.async.} =
  try:
    while true:
      let q = await imgIn.pop
      checkNil(q):
        asyncSpawn processImgData(q)
  except:
    let e = getCurrentException()[]
    warn "imageflow: image handler crashed. {e}"
    quitl()

proc imgHandler*() =
  waitFor asyncImgHandler()

proc startImgFlow*() =
  try:
    # start img handler thread
    setNil(imgIn):
      newAsyncPColl[ptr ImgQuery]()
    setNil(imgOut):
      newAsyncTable[ptr ImgQuery, ptr ImgData]()
    setNil(imgLock):
      create(AsyncLock)
    reset(imgLock[])
    imgLock[] = newAsyncLock()
    createThread(iflThread, imgHandler)
  except Exception as e:
    warn "Could not init imageflow! \n {e[]}"
    quitl()

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
