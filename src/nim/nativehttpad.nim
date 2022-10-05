import std/[os, monotimes, httpcore, uri, httpclient, net, asyncdispatch, hashes, locks]
import chronos/timer
from asyncfutures import asyncCheck
import utils
from cfg import PROXY_EP

var
  proxy: ptr Proxy
  sslContext: ptr SSLContext

const DEFAULT_TIMEOUT = 4.seconds # 4 seconds

type
  TimeoutError* = object of CatchableError
  RequestError* = object of CatchableError

type
  RequestObj = object
    url*: Uri
    meth*: HttpMethod
    headers*: HttpHeaders
    body*: string
    redir*: bool
  Request* = ptr RequestObj

  ResponseObj* = object
    code*: HttpCode
    headers*: HttpHeaders
    body*: string
  Response* = ptr ResponseObj
var
  httpThread: Thread[void]
  httpIn*: LockDeque[(MonoTime, Request)]
  httpOut*: LockTable[(MonoTime, Request), Response]

proc hash(rq: Request): Hash = hash(rq.url)

proc wait[T](fut: Future[T], timeout: Duration): Future[T] {.async.} =
  let start = Moment.now()
  while true:
    if fut.finished():
      result = fut.read()
      break
    elif Moment.now() - start > timeout:
      raise newException(TimeoutError, "Timeout exceeded!")
    else:
      await sleepAsync(1)

proc new*(_: typedesc[Response]): Response = create(ResponseObj)
proc new*(_: typedesc[Request], url: Uri, met: HttpMethod = HttpGet,
          headers: HttpHeaders = nil, body = "", redir = true): Request =
  result = create(RequestObj)
  result.url = url
  result.meth = met
  result.body = body
  result.headers = headers
  result.redir = redir

proc getClient(redir=true): AsyncHttpClient =
  newAsyncHttpClient(
    maxRedirects=(if redir: 5 else: 0),
    proxy=newProxy(PROXY_EP),
    sslContext=newContext(verifyMode = CVerifyNone)
  )

proc doReq(t: MonoTime, rq: Request, timeout = DEFAULT_TIMEOUT) {.async.} =
  let r = new(Response)
  let e = newException(RequestError, "Bad code.")
  var cl: AsyncHttpClient
  try:
    cl = getClient(rq.redir)
    let resp = await cl.request(rq.url, httpMethod = rq.meth,
        headers = rq.headers, body = rq.body).wait(timeout)
    r.code = resp.code
    r.headers = resp.headers
    if r.code == Http200:
      r.body = await resp.body
  except CatchableError: # timeout?
    discard
  finally:
    if not cl.isnil:
      cl.close()
  # the response
  httpOut[(t, rq)] = r

proc popFirstAsync[T](q: LockDeque[T]): Future[T] {.async.} =
  while true:
    if q.len > 0:
      result = q.popFirst()
      break
    else:
      await sleepAsync(1)

proc clearFuts(futs: var seq[Future]) =
  var toKeep: seq[Future]
  for f in futs:
    if not f.finished:
        toKeep.add(f)
  futs = toKeep

proc asyncHttpHandler() {.async.} =
  while true:
    try:
      warn "http: starting httpHandler..."
      var futs: seq[Future[void]]
      while true:
        clearFuts(futs)
        let (t, rq) = await httpIn.popFirstAsync
        futs.add doReq(t, rq)
    except:
      let e = getCurrentException()
      warn "http: httpHandler crashed. {e[]}"

proc httpHandler() =
  waitFor asyncHttpHandler()

proc initHttp*() =
  setNil(httpIn):
    initLockDeque[(MonoTime, Request)](100)
  setNil(httpOut):
    initLockTable[(MonoTime, Request), Response]()
  createThread(httpThread, httpHandler)
