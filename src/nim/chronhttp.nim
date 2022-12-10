import chronos except TLSFLags
import chronos/apps/http/httpclient except TLSFlags
import httputils
import std/[httpcore, tables, monotimes, hashes, uri, macros, sequtils]

import types, pyutils, utils, httptypes, locktplutils

var handler: Thread[void]
var sem: AsyncSemaphore
var futs {.threadvar.}: seq[Future[void]]
const chronHttpDebug {.booldefine.} = false
const maxConcurrentRequests {.intdefine.} = 200

template cdebug(code) =
  # Failed requests stacktraces are too noisy
  when chronHttpDebug:
    code

converter toUtilsMethod(m: httpcore.HttpMethod): httputils.HttpMethod =
  case m:
    of HttpHead: MethodHead
    of HttpGet: MethodGet
    of HttpPost: MethodPost
    of HttpPut: MethodPut
    of HttpDelete: MethodDelete
    of HttpTrace: MethodTrace
    of HttpOptions: MethodOptions
    of HttpConnect: MethodConnect
    of HttpPatch: MethodPatch

proc toHeaderTuple(h: HttpHeaders): seq[HttpHeaderTuple] =
  if h.isnil:
    return
  for (k, v) in h.pairs:
    when v is seq:
      for l in v:
        result.add (k, l)
    else:
      result.add (k, v)

converter tobytes(s: string): seq[byte] = cast[seq[byte]](s.toSeq())
# converter toHeaders(t: HttpTable) =

const proxiedFlags = {NoVerifyHost, NoVerifyServerName, NewConnectionAlways}
const sessionFlags = {NoInet6Resolution}
proc requestTask(q: sink ptr Request) {.async.} =
  withSem(sem)
  var trial = 0
  var
    sess: HttpSessionRef
    req: HttpClientRequestRef
    resp: HttpClientResponseRef
    cleanup: seq[Future[void]]
  while trial < q[].retries:
    try:
      trial.inc
      sess = new(HttpSessionRef,
                proxyTimeout = 10.seconds.div(3),
                headersTimeout = 10.seconds.div(2),
                connectTimeout = 10.seconds,
                proxy = if q[].proxied: selectProxy(trial) else: "",
                flags = if q[].proxied: proxiedFlags else: sessionFlags
      )
      req = new(HttpClientRequestRef,
                sess,
                sess.getAddress(q[].url).get,
                q[].meth,
                headers = q[].headers.toHeaderTuple,
                body = q[].body.tobytes,
        )
      resp = await req.fetch(followRedirects = q[].redir, raw = true)
      checkNil(resp):
        defer:
          cleanup.add resp.closeWait()
          resp = nil
        q.response.code = httpcore.HttpCode(resp.status)
        checkNil(resp.connection):
          q.response.body = bytesToString (await resp.getBodyBytes)
          q.response.headers = newHttpHeaders(cast[seq[(string, string)]](
              resp.headers.toList))
        break
    except:
      cdebug():
        logexc()
        debug "cronhttp: request failed"
    finally:
      if not req.isnil:
        cleanup.add req.closeWait()
      if not resp.isnil:
        cleanup.add resp.closeWait()
      if not sess.isnil:
        cleanup.add sess.closeWait()
  httpOut[q] = true
  await allFutures(cleanup)

proc requestHandlerAsync() {.async.} =
  # var q: Request
  while true:
    try:
      var q: ptr Request
      while true:
        # q = await httpIn.popFirstWait()
        pop(httpIn, q)
        clearFuts(futs)
        checkNil(q):
          futs.add requestTask(move q)
    except:
      logexc()
      warn "Chronos http handler crashed, restarting."
      await sleepAsync(1.seconds)

proc requestHandler() = waitFor requestHandlerAsync()

# proc httpGet*(url: string; headers: HttpHeaders = nil;
#               decode = Decode.yes; proxied = false): Future[Response] {.async,
#                   raises: [Defect].} =
#   var q: Request
#   q.id = getMonoTime()
#   q.meth = HttpGet
#   q.url = url.parseUri
#   q.headers =
#     if headers.isnil: newHttpHeaders()
#     else: headers
#   q.decode = decode
#   q.proxied = proxied
#   httpIn.add q.addr
#   discard await httpOut.pop(q.addr)
#   checkNil(q.response):
#     result = q.response[]

proc initHttp*() {.gcsafe.} =
  httptypes.initHttp()
  sem = init(AsyncSemaphore, maxConcurrentRequests)
  if not handler.running:
    createThread(handler, requestHandler)
