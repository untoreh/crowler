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
  ImgData = object
    mime, data: string
  ImgQuery = object
    id: MonoTime
    url, width, height: string
    processed: ptr Imgdata

const rxPathImg = "/([0-9]{1,3})x([0-9]{1,3})/\\?u=(.+)(?=/|$)"
var
  iflThread: Thread[void]
  imgIn: AsyncPColl[ptr ImgQuery]
  imgOut: AsyncTable[ptr ImgQuery, bool]
  imgLock: ptr AsyncLock
  imgCache: LockLruCache[string, string]
  futs {.threadvar.}: seq[Future[void]]

proc rawImg(imgurl: string): Future[string] {.inline, gcsafe, async.} =
  try:
    result = imgCache.lgetOrPut(imgurl):
      await getImg(imgurl, kind=urlsrc)
  except:
    logexc()

proc parseImgUrl*(relpath: string): ImgQuery =
  let m = relpath.match(sre rxPathImg).get
  let imgCapts = m.captures.toSeq

  result.id = getMonoTime()
  result.url = imgCapts[2].get
  result.width = imgCapts[0].get
  result.height = imgCapts[1].get

proc handleImg*(relpath: string): Future[(string, string)] {.async.} =
  var q = parseImgUrl(relpath)
  if q.url.isSomething:
    var decodedUrl = q.url.asBString.toString(true)
    debug "img: decoded url: {decodedUrl}"
    # block unused resize requests
    if not (fmt"{q.width}x{q.height}" in IMG_SIZES):
      result[0] = await decodedUrl.rawImg
    else:
      q.url = decodedUrl
      var processed: ImgData
      q.processed = processed.addr
      imgIn.add q.addr
      discard await imgOut.pop(q.addr)
      result = (processed.data, processed.mime)
      debug "ifl server: img processed"

proc processImgData(q: ptr ImgQuery) {.async.} =
  # push img to imageflow context
  var acquired, submitted: bool
  let data = (await q.url.rawImg)
  defer:
    if acquired: imgLock[].release
    if not submitted:
      imgOut[q] = true
  if data.len > 0:
    try:
      await imgLock[].acquire
      acquired = true
      if addImg(data):
        let query = fmt"width={q.width}&height={q.height}&mode=max&format=webp"
        logall "ifl server: serving image hash: {hash(await q.url.rawImg)}, size: {q.width}x{q.height}"
        # process and send back
        (q.processed.data, q.processed.mime) = processImg(query)
        imgOut[q] = true
        submitted = true
    except Exception:
      logexc()
      discard

proc asyncImgHandler() {.async.} =
  try:
    var img: ptr ImgQuery
    while true:
      imgIn.pop(img)
      clearFuts(futs)
      checkNil(img):
        futs.add processImgData(move img)
  except:
    logexc()
    warn "imageflow: image handler crashed."
    quitl()

proc imgHandler*() =
  initImageFlow() # NOTE: this initializes thread vars
  setNil(imgCache):
    initLockLruCache[string, string](32)
  while true:
    waitFor asyncImgHandler()
    sleep(1000)

proc startImgFlow*() =
  try:
    # start img handler thread
    setNil(imgIn):
      newAsyncPcoll[ptr ImgQuery]()
    setNil(imgOut):
      newAsyncTable[ptr ImgQuery, bool]()
    setNil(imgLock):
      let p = create(AsyncLock)
      p[] = newAsyncLock()
      p
    if not iflThread.running:
      createThread(iflThread, imgHandler)
  except:
    logexc()
    warn "Could not init imageflow."
    quitl()

# when isMainModule:
#     var srv = new GuildenServer
#     registerThreadInitializer(initThreadBase)
#     registerThreadInitializer(initWrapImageFlow)
#     srv.initHeaderCtx(handleGet, 5051, false)
#     echo "GuildenStern HTTP server serving at 5050"
#     srv.serve(loglevel = INFO)
