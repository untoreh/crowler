import nimpy
import std/[httpcore, tables, monotimes, hashes, uri, macros]
import chronos
import chronos/timer

import types, pyutils, utils, httptypes


pygil.globalAcquire()
pyObjPtr((fetchData, ut[].getAttr("fetch_data")))
pygil.release()

var handler: ptr Future[void]
var futs {.threadvar.}: seq[Future[void]]

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

proc pyReqGet(url: string, dodec: Decode, proxied: bool): Future[Response] {.async.} =
  env()
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[],
                          url,
                          decode = bool(dodec),
                          depth = proxied.int )
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
                          depth = q.proxied.int
        )
  var obj = await pywait(move j)
  result = await toResponse(move obj)

proc requestTask(q: ptr Request) {.async.} =
  try:
    let resp =
      if q.meth == HttpGet:
        await pyReqGet($q.url, q.decode, q.proxied)
      else: # post
        await pyReqPost(q)
    new(q.response)
    q.response[] = resp
  except:
    discard
  httpOut[q] = true

proc requestHandler() {.async.} =
  # var q: Request
  while true:
    try:
      while true:
        # q = await httpIn.popFirstWait()
        let q = await pop(httpIn)
        clearFuts(futs)
        checkNil(q):
          futs.add requestTask(q)
    except:
      logexc()
      warn "PyRequests handler crashed, restarting."
      await sleepAsync(1.seconds)

proc initHttp*() {.gcsafe.} =
  httptypes.initHttp()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()


proc httpGet*(url: string; headers: HttpHeaders = nil;
              decode = Decode.yes, proxied = false): Future[Response] {.async,
                  raises: [Defect].} =
  var q: Request
  q.id = getMonoTime()
  q.meth = HttpGet
  q.url = url.parseUri
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  q.proxied = proxied
  httpIn.add q.addr
  discard await httpOut.pop(q.addr)
  checkNil(q.response)
  result = q.response[]

# `redir` is stub for compat
macro get*(url: Uri; redir = false, decode = true, proxied = false, args: varargs[
    untyped]): untyped =
  quote do:
    httpGet($`url`, `args`, proxied = `proxied`)

macro get*(url: string;
           headers: HttpHeaders = nil,
           redir = false,
           decode = true,
           proxied = false
           ): untyped =
  quote do:
    httpGet(`url`, `headers`, `decode`, `proxied`)

proc httpPost*(url: string,
               headers: HttpHeaders = nil,
               body: sink string = "",
               decode = Decode.yes,
               proxied = false): Future[
                 Response] {.async,
                             raises: [Defect].} =
  var q: Request
  q.id = getMonoTime()
  q.meth = HttpPost
  q.url = url.parseUri
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  q.proxied = proxied
  q.body = body
  httpIn.add q.addr
  discard await httpOut.pop(q.addr)
  checkNil(q.response)
  result = q.response[]

template post*(url: Uri, args: varargs[untyped]): untyped = httpPost($url, args)

when isMainModule:
  initHttp()
  let url = "https://httpbin.org/get".parseUri
  let resp = waitFor get(url, proxied=true)
  echo resp.code
  echo resp.body[]
  # let headers = [("accept", "application/json")].newHttpHeaders()
  # echo waitFor post(url, headers = headers)
