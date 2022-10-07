import nimpy
import std/monotimes
import chronos
import chronos/timer

import types, pyutils, quirks, utils

type Decode = enum no, yes
converter asDec*(b: bool): Decode =
  if b: Decode.yes
  else: Decode.no

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

proc pyReqGet(url: string, dodec: Decode): Future[string] {.async.} =
  var rdy: bool
  var res: string
  var j: PyObject
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[], url, decode=bool(dodec))
  let resp = await pywait(j)
  withPyLock:
    result = resp.to(string)

var queue: LockDeque[(MonoTime, string, Decode)]
var httpResults: LockTable[(MonoTime, string, Decode), string]
var handler: ptr Future[void]

proc requestTask(t: MonoTime, url: string, decode: Decode) {.async.} =
  var v: string
  try:
    v = await pyReqGet(url, decode)
  except:
    discard
  httpResults[(t, url, decode)] = v


import locktplutils
proc requestHandler() {.async.} =
  var
    t: MonoTime
    url: string
    decode: Decode
  while true:
    try:
      while true:
        (t, url, decode) = await queue.popFirstWait()
        asyncSpawn requestTask(t, url, decode)
    except Exception as e:
      warn "PyRequests handler crashed, restarting. {e[]}"
      await sleepAsync(1.seconds)

proc initPyHttp*() {.gcsafe.} =
  setNil(queue):
    initLockDeque[(MonoTime, string, Decode)]()
  setNil(httpResults):
    initLockTable[(MonoTime, string, Decode), string]()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()

proc httpGet*(url: string, decode=Decode.yes): Future[string] {.async, raises: [Defect].} =
  let k = (getMonoTime(), url, decode)
  queue.addLast(k)
  return await httpResults.popWait(k)

when isMainModule:
  initPyHttp()
  echo waitFor httpGet("https://google.com")
