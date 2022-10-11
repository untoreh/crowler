import std/[os, monotimes, httpcore, uri, asyncnet, net,
            asyncdispatch, hashes, locks, strutils]
from asyncfutures import asyncCheck
import httpclient except Response
import chronos/timer
import httptypes
import sharedqueue
import utils
import ./harpoon
from cfg import PROXY_EP

var
  proxy: ptr Proxy
  sslContext: ptr SSLContext

const DEFAULT_TIMEOUT = 4.seconds # 4 seconds

var httpThread: Thread[void]

# proc hash(rq: ptr Request): Hash = hash(rq.url)

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

proc new*(_: typedesc[Request], url: Uri, met: HttpMethod = HttpGet,
          headers: HttpHeaders = nil, body = "", redir = true): RequestRef =
  result = new(Request)
  result.url = url
  result.meth = met
  result.body = body
  result.headers = headers
  result.redir = redir

import nimSocks/[types, client]
const PROXY_HOST = parseUri(PROXY_EP).hostname
const PROXY_PORT = parseUri(PROXY_EP).port.parseInt.Port
const PROXY_METHODS = {NO_AUTHENTICATION_REQUIRED, USERNAME_PASSWORD}

proc getPort(url: Uri): Port =
  case url.scheme:
    of "http": Port 80
    of "https": Port 443
    else: Port 80

proc getConn(url: Uri, port: Port, proxied: bool): Future[AsyncSocket] {.async.} =
  var sock: AsyncSocket
  try:
    if proxied:
      sock = await asyncnet.dial(PROXY_HOST, PROXY_PORT)
      if not proxied:
        return sock
      if not await sock.doSocksHandshake(methods = PROXY_METHODS):
        sock.close
        raise newException(OSError, "Proxy error.")
      if not await sock.doSocksConnect(url.hostname, port):
        sock.close
        raise newException(OSError, "Proxy error.")
    else:
      sock = newAsyncSocket()
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

proc doReq(rq: ptr Request, timeout = 4000) {.async.} =
  let r = newResponse()
  # defer: maybefree(r)
  let e = newException(RequestError, "Bad code.")
  var conn: AsyncSocket
  try:
    let port = rq.url.getPort()
    conn = await getConn(rq.url, port, rq.proxied)
    let resp = await fetch(conn,
                           $rq.url,
                           metod = rq.meth,
                           headers = rq.headers,
                           body = rq.body,
                           timeout = timeout,
                           skipConnect = rq.proxied,
                           port = port,
                           portSsl = port
                           )
    r.code = resp.code
    r.headers = create(HttpHeaders)
    r.headers[] = resp.headers.toHeaders()
    r.body = create(string)
    r.body[] = resp.body
  except CatchableError as e: # timeout?
    echo e[].msg
    discard
  finally:
    if not conn.isnil:
      conn.close()
  # the response
  httpOut[rq] = r

# proc popFirstAsync[T](q: LockDeque[T]): Future[T] {.async.} =
#   while true:
#     if q.len > 0:
#       result = q.popFirst()
#       break
#     else:
#       await sleepAsync(1)

import std/importutils
proc pop[T](apc: AsyncPColl[T]): Future[T] {.async.} =
  privateAccess(AsyncPColl)
  while true:
    withLock(apc.lock):
      if apc.pcoll.len > 0:
        doassert apc.pcoll.pop(result)
        break
    await sleepAsync(1)

proc asyncHttpHandler() {.async.} =
  var rq: ptr Request
  while true:
    try:
      warn "http: starting httpHandler..."
      # var futs: seq[Future[void]]
      while true:
        # clearFuts(futs)
        rq = await httpIn.pop
        if not rq.isnil:
          asyncCheck doReq(rq)
        # futs.add doReq(t, rq)
    except:
      let e = getCurrentException()
      warn "http: httpHandler crashed. {e[].msg}"

proc httpHandler() =
  waitFor asyncHttpHandler()

proc initHttp*() =
  httpTypes.initHttp()
  createThread(httpThread, httpHandler)
