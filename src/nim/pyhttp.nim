import nimpy
import std/[httpcore, tables, monotimes, hashes, uri, macros]
import chronos
import chronos/timer

import types, pyutils, quirks, utils, httptypes

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
      withPyLock:
        res = j.getAttr("get")()
      break
    await sleepAsync(250.milliseconds)
  withPyLock:
    result =
      if (not res.isnil) and (not res.pyisnone) and $res != "<NULL>":
        res
      else:
        raise newException(ValueError, "Python job failed.")


type Query = object
    id: MonoTime
    met: HttpMethod
    url: ref string
    headers: HttpHeaders
    body: ref string
    decode: Decode
proc hash(q: Query): Hash = hash((q.id, q.met, key(q.url[]), key(q.body[])))

var queue: LockDeque[Query]
var httpResults: LockTable[Query, Response]
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
    for tup in obj.getAttr("items")():
      result[tup[0].to(string)] = tup[1].to(string)

proc toResponse(obj: PyObject): Future[Response] {.async.} =
  withPyLock:
    if not pyisnone(obj):
      result.code = obj.status.to(int).HttpCode
      result.headers = obj.headers.pyToHeaders
      result.body = obj.data.to(string)

proc pyReqGet(url: string, dodec: Decode): Future[Response] {.async.} =
  env()
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[], url, decode = bool(dodec))
  let obj = await pywait(j)
  result = await obj.toResponse

proc pyReqPost(q: Query): Future[Response] {.async.} =
  env()
  withPyLock:
    {.cast(gcsafe).}:
      j = pySched[].apply(fetchData[],
                          q.url[],
                          meth = $q.met,
                          headers = q.headers.headersToPy(),
                          body = q.body[],
                          decode = bool(q.decode),
                          fromcache = false
        )
  let obj = await pywait(j)
  result = await obj.toResponse

proc requestTask(q: Query) {.async.} =
  var v: Response
  try:
    v =
      if q.met == HttpGet:
        await pyReqGet(q.url[], q.decode)
      else: # post
        await pyReqPost(q)
  except:
    discard
  httpResults[q] = v

import locktplutils
proc requestHandler() {.async.} =
  var q: Query
  while true:
    try:
      while true:
        q = await queue.popFirstWait()
        asyncSpawn requestTask(q)
    except Exception as e:
      warn "PyRequests handler crashed, restarting. {e[]}"
      await sleepAsync(1.seconds)

proc initPyHttp*() {.gcsafe.} =
  setNil(queue):
    initLockDeque[Query]()
  setNil(httpResults):
    initLockTable[Query, Response]()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()


proc httpGet*(url: string; headers: HttpHeaders = nil;
              decode = Decode.yes): Future[Response] {.async,
                  raises: [Defect].} =
  var q: Query
  q.id = getMonoTime()
  q.met = HttpGet
  new(q.url)
  q.url[] = url
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  new(q.body)
  queue.addLast(q)
  return await httpResults.popWait(q)

# `redir` is stub for compat
macro get*(url: Uri; redir = false, args: varargs[
    untyped]): untyped =
  quote do:
    httpGet($`url`, `args`)

proc httpPost*(url: string, headers: HttpHeaders = nil, body: sink string = "",
    decode = Decode.yes): Future[Response] {.async, raises: [Defect].} =
  var q: Query
  q.id = getMonoTime()
  q.met = HttpPost
  new(q.url)
  q.url[] = url
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  new(q.body)
  q.body[] = body
  queue.addLast(q)
  return await httpResults.popWait(q)

template post*(url: Uri, args: varargs[untyped]): untyped = httpPost($url, args)

when isMainModule:
  initPyHttp()
  let url = "https://httpbin.org/get".parseUri
  echo waitFor get(url)
  # let headers = [("accept", "application/json")].newHttpHeaders()
  # echo waitFor post(url, headers = headers)
