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

proc getImpl(rqPtr: ptr Request): Future[void] {.async.} =
  ## NOTE: Response can be nil
  checkNil rqPtr
  httpIn.add rqPtr
  let status = await httpOut.pop(rqPtr)
  if not status:
    raise newException(RequestError, "GET request failed.")
  elif rqPtr[].response.isnil:
    raise newException(RequestError, "GET request failed. Response is nil.")

proc request*(uri: Uri,
              meth = HttpGet,
              headers: HttpHeaders = nil,
              body = "",
              redir = true,
              proxied = true,
              decode = true,
              ): Future[Response] {.async.} =
  var rq: Request
  rq.init(uri, meth, headers, body, redir, proxied)
  rq.response = result.addr
  try:
    await getImpl(rq.addr)
    checkNil(result.headers)
    return
  except:
    logexc()
  raiseRequestError("request: failed.")

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
