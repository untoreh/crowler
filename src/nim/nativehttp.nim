import std/[os, monotimes, httpcore, uri, locks, deques]
import chronos

import httptypes except initHttp
import
  utils,
  pyhttp
  # nativehttpha,
  # nativehttpad,


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
  let respPtr = await httpOut.pop(rq.addr)
  defer: free(respPtr)
  if respPtr.isnil:
    raise newException(RequestError, "GET request failed, response is nil.")
  else:
    result = move respPtr[]

proc request*(uri: Uri, meth = HttpGet, headers: HttpHeaders = nil,
                               body = "", redir = true, proxied = true,
                                   retries = 5): Future[Response] {.async.} =
  var resp: Response
  for r in 0..<retries:
    try:
      resp = await getImpl(uri, meth, headers, body, redir, proxied)
      if resp.headers.isnil:
        continue
      return resp
    except CatchableError:
      echo getCurrentException()[]
      continue
  raiseRequestError("Request failed, retries exceeded.")

import macros
macro request*(uri: string, args: varargs[untyped]): untyped =
  quote do:
    request(`uri`, `args`)

macro get*(url: Uri; redir = true; decode = false; proxied = true;
    args: varargs[untyped]): untyped =
  quote do:
    request(`url`, proxied = `proxied`, `args`)

macro get*(url: string; args: varargs[untyped]): untyped =
  quote do:
    request(parseUri(`url`), `args`)

proc post*(uri: Uri; headers: HttpHeaders = nil; body = ""): Future[
    Response] {.async.} =
  return await request(uri, meth = HttpPost, headers = headers, body = body)

template post*(url: string, args: varargs[untyped]): Future[Response] =
  post(parseUri(url), args)

when isMainModule:
  import uri
  when declared(pyhttp):
    initPyHttp()
  else:
    initHttp()
  let u = "https://ipinfo.io/ip".parseUri
  let resp = waitFor get(u)
  echo resp.code
  echo resp.body[]
