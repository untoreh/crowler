import nimpy
import chronos
import chronos/timer
import utils, quirks
import types

pygil.globalAcquire()
let
  httpCache = initLockLruCache[string, string](32)
  requests = pyImport("requests")
  PyReqGet = requests.getAttr("get")
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
      if (not res.isnil) and (not ($res in ["<NULL>", "None"])):
        res
      else:
        raise newException(ValueError, "Python job failed.")

template pyReqGetImpl(url: string): string =
  var rdy: bool
  var res: string
  var j: PyObject
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(PyReqGet, url)
  let resp = await pywait(j)
  defer:
    withPyLock:
      discard resp.getAttr("close")
  withPylock:
    res = resp.content.to(string)
  res

proc pyReqGet*(url: string): Future[string] {.async, gcsafe.} =
  result =
    httpCache.lcheckOrPut(url):
      pyReqGetImpl(url)

when isMainModule:
  echo waitFor pyReqGet("https://google.com")
