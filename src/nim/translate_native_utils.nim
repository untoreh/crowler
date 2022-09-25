import chronos/apps/http/httpclient
import chronos/timer
import std/uri
import macros
from cfg import PROXY_EP
export PROXY_EP

const
  DEFAULT_TIMEOUT* = 5.seconds

type TranslateError* = object of ValueError
proc raiseTranslateError*(msg: string) =
  raise newException(TranslateError, msg)

type
  Query* = tuple[text: string, src: string, trg: string]
  TranslateFunc* = proc(text, src, trg: string): Future[string] {.gcsafe.}
  TranslateObj* = object of RootObj
    session*: HTtpSessionRef
    translateImpl*: TranslateFunc
    maxQuerySize*: int
  Translate* = ref TranslateObj
  TranslatePtr* = ptr TranslateObj

proc doReq*(self: TranslateObj, uri: Uri, retries = 10): Future[
    string] {.async.} =
  for r in 0..<retries:
    try:
      let resp = await self.session.fetch(uri)
      if resp.status != 200:
        continue
      return bytesToString resp.data
    except CatchableError:
      continue
  raiseTranslateError "Translation request failed."

macro ensureClosed*(objs: varargs[untyped]): untyped =
  let stmt = newNimNode(nnkStmtList)
  stmt.add quote do:
    var pending {.inject.}: seq[Future[void]]
  for o in objs:
    stmt.add quote do:
      if not(isNil(`o`)): pending.add closeWait(`o`)
  stmt.add quote do:
    await allFutures(pending)
  result = newBlockStmt(stmt)

template sendReq*(req): HttpClientResponseRef =
  block:
    var
      req = req
      redir: HttpClientRequestRef
      resp: HttpClientResponseRef
    for _ in 0..<10:
      try:
        resp = await req.send()
        break
      except CatchableError as e:
        redir =
          block:
            let res = req.redirect(req.address)
            if res.isErr:
              raiseTranslateError "Translation request failed at redirect."
            res.get
        ensureClosed(resp, req)
        req = nil
        req = redir
    ensureClosed(redir, req)
    redir = nil
    if resp.isnil:
      raiseTranslateError "Translation request failed."
    resp

proc init*[T: TranslateObj](_: typedesc[T], timeout: Duration = 3.seconds,
                            useProxies = true): T =
  result.maxQuerySize = 5000
  result.session =
    new(HttpSessionRef,
    connectTimeout = timeout,
    headersTimeout = timeout.div(2),
    proxyTimeout = timeout.div(3),
    proxy = if useProxies: PROXY_EP else: "",
    flags = if useProxies: {HttpClientFlag.NoVerifyHost,
        HttpClientFlag.NoVerifyServerName} else: {}
    # proxyAuth=proxyAuth("user", "pass")
    )

proc parseCookies*(resp: HttpClientResponseRef): string =
  for ck in resp.headers.getList("set-cookie"):
    let cks = ck.split(";")
    if len(cks) > 0:
      result.add cks[0]
      result.add "; "

template setTranslateClosure*() =
  proc fn(text, src, trg: string): Future[string] {.async.} =
    return await srv.translate(text, src, trg)
  srv.translateImpl = fn
