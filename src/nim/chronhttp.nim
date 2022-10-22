import chronos except TLSFLags
import chronos/apps/http/httpclient except TLSFlags
import httputils
import std/[httpcore, tables, monotimes, hashes, uri, macros, sequtils]

import types, pyutils, utils, httptypes
from cfg import PROXY_EP

var handler: ptr Future[void]

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
const sessionFlags = {NoVerifyHost, NoVerifyServerName}
proc requestTask(q: ptr Request) {.async.} =
  let v = create(Response)
  try:
    var resp: HttpClientResponseRef
    let
      sess = new(HttpSessionRef,
                proxyTimeout = 10.seconds.div(3),
                headersTimeout = 10.seconds.div(2),
                connectTimeout = 10.seconds,
                proxy = if q[].proxied: PROXY_EP else: "",
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
        asyncSpawn resp.closeWait()
        resp = nil
      init(v[])
      v[].code = httpcore.HttpCode(resp.status)
      checkNil(resp.connection):
        v[].body[] = bytesToString (await resp.getBodyBytes)
        v[].headers[] = newHttpHeaders(cast[seq[(string, string)]](
            resp.headers.toList))
  except CatchableError as e:
    debug "cronhttp: {e[]}"
    discard
  httpOut[q] = v

proc requestHandler() {.async.} =
  # var q: Request
  while true:
    try:
      while true:
        # q = await httpIn.popFirstWait()
        let q = await pop(httpIn)
        checkNil(q):
          asyncSpawn requestTask(q)
    except Exception as e:
      warn "Chronos http handler crashed, restarting. {e[]}"
      await sleepAsync(1.seconds)

proc httpGet*(url: string; headers: HttpHeaders = nil;
              decode = Decode.yes; proxied = false): Future[Response] {.async,
                  raises: [Defect].} =
  var q: Request
  q.id = getMonoTime()
  q.meth = HttpGet
  q.url = url.parseUri
  q.headers =
    if headers.isnil: newHttpHeaders()
    else: headers
  q.decode = decode
  q.proxied = proxied
  httpIn.add q.addr
  let resp = await httpOut.pop(q.addr)
  defer: free(resp)
  checkNil(resp):
    result = resp[]

proc initHttp*() {.gcsafe.} =
  httptypes.initHttp()
  setNil(handler):
    create(Future[void])
  handler[] = requestHandler()
