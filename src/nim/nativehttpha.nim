import std/[os, monotimes, httpcore, uri, httpclient, asyncnet, net,
            asyncdispatch, hashes, locks, strutils]
from asyncfutures import asyncCheck
import chronos/timer
import ./harpoon
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

import nimSocks/[types, client]
const PROXY_HOST = parseUri(PROXY_EP).hostname
const PROXY_PORT = parseUri(PROXY_EP).port.parseInt.Port
const PROXY_METHODS = {NO_AUTHENTICATION_REQUIRED, USERNAME_PASSWORD}

proc getConn(url: Uri): Future[AsyncSocket] {.async.} =
  var sock: AsyncSocket
  try:
    sock = await asyncnet.dial(PROXY_HOST, PROXY_PORT)
    if not await sock.doSocksHandshake(methods = PROXY_METHODS):
      raise newException(OSError, "Proxy error.")
    let port =
      case url.scheme:
        of "http": Port 80
        of "https": Port 443
        else: Port 80
    if not await sock.doSocksConnect(url.hostname, port):
      raise newException(OSError, "Proxy error.")
    return sock
  except Exception as e:
    if not sock.isnil:
      sock.close()
    raise e

converter toSeq(headers: HttpHeaders): seq[(string, string)] =
  if not headers.isnil:
    for (k, v) in headers.pairs():
        result.add (k, v)

converter toHeaders(s: seq[(string, string)]): HttpHeaders = s.newHttpHeaders()

proc doReq(t: MonoTime, rq: Request, timeout = 4000) {.async.} =
  let r = new(Response)
  let e = newException(RequestError, "Bad code.")
  var conn: AsyncSocket
  try:
    conn = await getConn(rq.url)
    let resp = await fetch(conn,
                           $rq.url,
                           metod = rq.meth,
                           headers = rq.headers,
                           body = rq.body,
                           timeout = timeout,
                           skipConnect = true,
                           )
    r.code = resp.code
    r.headers = resp.headers
    r.body = resp.body
  except CatchableError as e: # timeout?
    # echo e[].msg
    discard
  finally:
    if not conn.isnil:
      conn.close()
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
      # var futs: seq[Future[void]]
      while true:
        # clearFuts(futs)
        let (t, rq) = await httpIn.popFirstAsync
        asyncCheck doReq(t, rq)
        # futs.add doReq(t, rq)
    except:
      let e = getCurrentException()
      warn "http: httpHandler crashed. {e[].msg}"

proc httpHandler() =
  waitFor asyncHttpHandler()

proc initHttp*() =
  setNil(httpIn):
    initLockDeque[(MonoTime, Request)](100)
  setNil(httpOut):
    initLockTable[(MonoTime, Request), Response]()
  createThread(httpThread, httpHandler)
