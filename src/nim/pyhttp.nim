import nimpy
import std/[httpcore, tables, monotimes, hashes, uri, macros]
import chronos
import chronos/timer

import types, pyutils, utils, httptypes


pygil.globalAcquire()
pyObjPtr((fetchData, ut[].getAttr("fetch_data")))
pygil.release()

var handler: ptr Future[void]

template env() {.dirty.} =
  var rdy: bool
  var res: string
  var j: PyObject

proc headersToPy(headers: HttpHeaders): PyObject =
  {.locks: [pygil].}:
    result = pybi[].dict()
    for (k, v) in headers.pairs:
      when v is seq:
        for l in v:
          result[k] = l
      else:
        result[k] = v

proc pyToHeaders(obj: PyObject): HttpHeaders =
  ## Needs to be locked
  result = newHttpHeaders()
  if pytype(obj) == "dict":
    for tup in obj.callMethod("items"):
      result[tup[0].to(string)] = tup[1].to(string)

proc toResponse(obj: PyObject): Future[Response] {.async.} =
  init(result)
  withPyLock:
    if not pyisnone(obj):
      result.code = obj.status.to(int).HttpCode
      result.headers[] = obj.headers.pyToHeaders
      result.body[] = obj.data.to(string)

proc pyReqGet(url: string, dodec: Decode): Future[Response] {.async.} =
  env()
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[], url, decode = bool(dodec))
  var obj = await pywait(j)
  result = await toResponse(move obj)

proc pyReqPost(q: ptr Request): Future[Response] {.async.} =
  env()
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[],
                          $q.url,
                          meth = $q.meth,
                          headers = q.headers.headersToPy(),
                          body = q.body,
                          decode = bool(q.decode),
                          fromcache = false
        )
  var obj = await pywait(move j)
  result = await toResponse(move obj)

proc requestTask(q: ptr Request) {.async.} =
  let v = create(Response)
  try:
    v[] =
      if q.meth == HttpGet:
        await pyReqGet($q.url, q.decode)
      else: # post
        await pyReqPost(q)
  except:
    discard
  httpOut[q] = v

proc requestHandler() {.async.} =
  # var q: Request
  while true:
    try:
      while true:
        # q = await httpIn.popFirstWait()
        let q = await pop(httpIn)
        checkNil(q):
          asyncSpawn requestTask(q)
    except Exception as e:
      warn "PyRequests handler crashed, restarting. {e[]}"
      await sleepAsync(1.seconds)

proc initHttp*() {.gcsafe.} =
  httptypes.initHttp()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()


proc httpGet*(url: string; headers: HttpHeaders = nil;
              decode = Decode.yes): Future[Response] {.async,
                  raises: [Defect].} =
  var q: Request
  q.id = getMonoTime()
  q.meth = HttpGet
  q.url = url.parseUri
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  httpIn.add q.addr
  let resp = await httpOut.pop(q.addr)
  defer: free(resp)
  checkNil(resp):
    result = resp[]

# `redir` is stub for compat
macro get*(url: Uri; redir = false, decode = true, args: varargs[
    untyped]): untyped =
  quote do:
    httpGet($`url`, `args`)

macro get*(url: string; headers: HttpHeaders = nil, redir = false,
                                               decode = true): untyped =
  quote do:
    httpGet(`url`, `headers`, `decode`, )

proc httpPost*(url: string, headers: HttpHeaders = nil, body: sink string = "",
    decode = Decode.yes): Future[Response] {.async, raises: [Defect].} =
  var q: Request
  q.id = getMonoTime()
  q.meth = HttpPost
  q.url = url.parseUri
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  q.body = body
  httpIn.add q.addr
  let resp = await httpOut.pop(q.addr)
  defer: free(resp)
  checkNil(resp):
    result = resp[]

template post*(url: Uri, args: varargs[untyped]): untyped = httpPost($url, args)

when isMainModule:
  initPyHttp()
  let url = "https://httpbin.org/get".parseUri
  let resp = waitFor get(url)
  echo resp.code
  echo resp.body[]
  # let headers = [("accept", "application/json")].newHttpHeaders()
  # echo waitFor post(url, headers = headers)
