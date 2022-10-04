import nimpy
import chronos
import chronos/timer

import types, pyutils, quirks, utils

pygil.globalAcquire()
pyObjPtr((fetchData, ut[].getAttr("fetch_data")))
pygil.release()

proc pywait(j: PyObject): Future[PyObject] {.async, gcsafe.} =
  var rdy: bool
  var res: PyObject
  while true:
    withPyLock:
      rdy = j.getAttr("ready")().to(bool)
    if rdy:
      withPyLock: res = j.getAttr("get")()
      break
    await sleepAsync(250.milliseconds)
  withPyLock:
    result =
      if (not res.isnil) and (not res.pyisnone) and $res != "<NULL>":
        res
      else:
        raise newException(ValueError, "Python job failed.")

proc pyReqGet(url: string): Future[string] {.async.} =
  var rdy: bool
  var res: string
  var j: PyObject
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[], url)
  let resp = await pywait(j)
  withPyLock:
    result = resp.to(string)

var queue: LockDeque[string]
var httpResults: LockTable[string, string]
var handler: ptr Future[void]

proc requestTask(url: string) {.async.} =
  var v: string
  try:
    v = await pyReqGet(url)
  except CatchableError:
    discard
  httpResults[url] = v


import locktplutils
proc requestHandler() {.async.} =
  var url: string
  while true:
    try:
      while true:
        url = await queue.popFirstWait()
        asyncSpawn requestTask(url)
    except Exception as e:
      warn "PyRequests handler crashed, restarting. {e[]}"
      await sleepAsync(1.seconds)

proc initPyHttp*() {.gcsafe.} =
  setNil(queue):
    initLockDeque[string]()
  setNil(httpResults):
    initLockTable[string, string]()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()

proc httpGet*(url: string): Future[string] {.async, raises: [Defect].} =
  queue.addLast(url)
  return await httpResults.popWait(url)

when isMainModule:
  initPyHttp()
  echo waitFor httpGet("https://google.com")
