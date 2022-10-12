import std/[os, monotimes, httpcore, uri, asyncnet, net,
            hashes, locks, strutils]
import asyncdispatch
import chronos as ch except async, Future
# from chronos as ch import nil
# import ad_chronos_adapter
import chronos/timer
import httptypes
import utils
import ./harpoon
from cfg import PROXY_EP

const DEFAULT_TIMEOUT = 4.seconds # 4 seconds

var httpThread: Thread[void]

# proc hash(rq: ptr Request): Hash = hash(rq.url)

import nimSocks/[types, client]
const PROXY_HOST = parseUri(PROXY_EP).hostname
const PROXY_PORT = parseUri(PROXY_EP).port.parseInt.Port
const PROXY_METHODS = {NO_AUTHENTICATION_REQUIRED, USERNAME_PASSWORD}

proc getPort(url: Uri): Port =
  case url.scheme:
    of "http": Port 80
    of "https": Port 443
    else: Port 80


import asyncdispatch except async, multisync, await, waitFor, Future,
    FutureBase, asyncSpawn, sleepAsync

# proc wait[T](fut: asyncdispatch.Future[T], timeout: Duration = 4.seconds): Future[T] {.async.} =
#   let start = Moment.now()
#   while true:
#     if fut.finished():
#       result = fut.read()
#       break
#     elif Moment.now() - start > timeout:
#       raise newException(TimeoutError, "Timeout exceeded!")
#     else:
#       await sleepAsync(1000)

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

import std/importutils
privateAccess(AsyncTable)
ch.async:
  proc put*[K, V](t: AsyncTable[K, V], k: K, v: V) =
    try:
      ch.await t.lock.acquire()
      if k in t.waiters[]:
        var ws: ptr seq[ptr Future[V]]
        doassert t.waiters[].pop(k, ws)
        defer: dealloc(ws)
        while ws[].len > 0:
          let w = ws[].pop()
          if not w.isnil:
            w[].complete(v)
      else:
        t.table[][k] = v
    finally:
      t.lock.release

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
    r.headers[] = resp.headers.toHeaders()
    r.body[] = resp.body
  except CatchableError as e: # timeout?
    echo e[].msg
    discard
  finally:
    if not conn.isnil:
      conn.close()
  # the response
  ch.await httpOut.put(rq, r)

ch.async:
  proc asyncHttpHandler() =
    var rq: ptr Request
    while true:
      try:
        warn "http: starting httpHandler..."
        while true:
          rq = ch.await httpIn.pop
          checkNil(rq):
            ch.asyncSpawn doReq(rq)
      except:
        let e = getCurrentException()
        warn "http: httpHandler crashed. {e[].msg}"

proc httpHandler() =
  ch.waitFor asyncHttpHandler()

proc initHttp*() =
  httpTypes.initHttp()
  createThread(httpThread, httpHandler)
