import std/[os, monotimes, httpcore, uri, locks, deques]
import chronos

import httptypes except initHttp
import
  utils,
  # pyhttp
  threadshttp
  # chronhttp


export Request, Response, RequestError, initHttp

proc raiseRequestError(msg = "Request failed.") =
  raise newException(RequestError, msg)

proc getImpl(url: Uri, meth: HttpMethod, headers: HttpHeaders = nil,
             body = "", redir = true, proxied = true): Future[
                 Response] {.async.} =
  ## NOTE: Response can be nil
  var rq: Request
  rq.init(url, meth, headers, body, redir, proxied)
  httpIn.add rq.addr
  let status = await httpOut.pop(rq.addr)
  if not status:
    raise newException(RequestError, "GET request failed.")
  elif rq.response.isnil:
    raise newException(RequestError, "GET request failed. Response is nil.")
  else:
    result = rq.response[]

proc request*(uri: Uri,
              meth = HttpGet,
              headers: HttpHeaders = nil,
              body = "",
              redir = true,
              proxied = true,
              decode = true,
              ): Future[Response] {.async.} =
  var resp: Response
  try:
    resp = await getImpl(uri, meth, headers, body, redir, proxied)
    checkNil(resp.headers)
    return resp
  except CatchableError:
    echo getCurrentException()[]
  raiseRequestError("Request failed, retries exceeded.")

type Url = string | Uri

proc asUri*(u: Url): Uri {.inline.} =
  when u is string:
    parseUri(u)
  else: u

template get*(url: Url; args: varargs[untyped]): untyped =
  request(url.asUri, HttpGet, args)

template post*(url: Url; args: varargs[untyped]): Future[Response] =
  request(url.asUri, HttpPost, args)

when isMainModule:
  initHttp()
  proc f() {.async.} =
    let u = "https://ipinfo.io/ip".parseUri
    let resp = await get(u, proxied = true)
    echo resp.code
    echo resp.body[]
  waitFor f()
