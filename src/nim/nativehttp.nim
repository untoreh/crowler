import std/[os, monotimes, httpcore, uri, locks, deques]
import chronos

import httptypes except initHttp
import
  utils,
  # pyhttp
  # harphttp
  # stdhttp
  chronhttp


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

proc request*(uri: Uri,
              meth = HttpGet,
              headers: HttpHeaders = nil,
              body = "",
              redir = true,
              proxied = true,
              decode = true,
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
  import uri
  import ad_chronos_adapter
  initHttp()
  let u = "https://ipinfo.io/ip".parseUri
  let resp = waitFor get(u, proxied = true)
  echo resp.code
  echo resp.body[]
