import std/[os, monotimes, httpcore, uri, locks, deques]
import chronos

import
  utils,
  locktplutils,
  nativehttpha
  # nativehttpad

export Request, Response, RequestError, initHttp

proc raiseRequestError(msg = "Request failed.") =
  raise newException(RequestError, msg)

proc getImpl(url: Uri, meth: HttpMethod, headers: HttpHeaders = nil,
             body = "", redir = true): Future[Response] {.async.} =
  ## NOTE: Response can be nil
  let rq = Request.new(url, meth, headers, body, redir)
  let k = (getMonoTime(), rq)
  httpIn.addLast k
  result = await httpOut.popWait(k)
  if result.isnil:
    raise newException(RequestError, "GET request failed, response is nil.")

proc request*(uri: Uri, meth = HttpGet, headers: HttpHeaders = nil,
                               body = "", redir = true, retries = 5): Future[Response] {.async.} =
  var resp: Response
  for r in 0..<retries:
    try:
      resp = await getImpl(uri, meth, headers, body, redir)
      if resp.isnil or resp.headers.isnil:
        continue
      return resp
    except CatchableError:
      echo getCurrentException()[]
      continue
  raiseRequestError("Request failed, retries exceeded.")

template request*(uri: string, args: varargs[untyped]): untyped =
  request(parseUri(uri), args)

proc get*(url: Uri, headers: HttpHeaders = nil, redir = true): Future[Response] {.async.} =
  return await request(url, headers=headers, redir=redir)

template get*(uri: string, args: varargs[untyped]): untyped =
  get(parseUri(uri), args)

proc post*(uri: Uri, headers: HttpHeaders = nil, body = ""): Future[
    Response] {.async.} =
  return await request(uri, meth = HttpPost, headers = headers, body = body)

template post*(url: string, args: varargs[untyped]): Future[Response] =
  post(parseUri(url), args)

when isMainModule:
  import uri
  initHttp()
  let u = "https://ipinfo.io/ip".parseUri
  let resp = waitFor get(u)
  echo resp.code
  echo resp.body
