import std/[parsexml, streams, uri, httpcore, nre, strformat, strutils, json]
import std/times except seconds, milliseconds
import chronos/apps/http/httpclient
import chronos
import chronos/asyncsync
from chronos/timer import seconds, milliseconds

from cfg import PROXY_EP
import types
import utils
import translate_native_utils

type
  BingConfig = ref object
    tld: string
    ig: string
    iid: string
    key: int
    token: string
    tokenTs: times.Time
    tokenExpiryInterval: int
    isVertical: bool
    frontDoorBotClassification: string
    isSignedInOrCorporateUser: bool
    cookie: string
    count: int
    lock: AsyncLock
  BingTranslateObj* = object of TranslateObj
    config: BingConfig
  BingTranslate* = ref BingTranslateObj
  BingTranslatePtr* = ptr BingTranslateObj

const
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.88 Safari/537.36"
  TRANSLATE_API_ROOT = "https://{config.tld}bing.com" # this is formatted, requires `var config: BingConfig`
  TRANSLATE_WEBSITE = TRANSLATE_API_ROOT & "/translator"
  TRANSLATE_API = TRANSLATE_API_ROOT & "/ttranslatev3"
  TRANSLATE_SPELL_CHECK_API = TRANSLATE_API_ROOT & "/tspellcheckv3"

var bt*: BingTranslatePtr

proc isTokenExpired(self: BingTranslateObj): bool =
  if self.config.isnil:
    raiseTranslateError("Config can't be nil.")
  if self.config.key == 0:
    return true
  let elapsedSeconds = (getTime() - self.config.tokenTs).inSeconds
  return elapsedSeconds > self.config.tokenExpiryInterval

proc buildReqUri(self: BingTranslateObj, isSpellCheck: static[
    bool] = false): Uri =
  let config = self.config
  const baseUrl = if isSpellCheck: TRANSLATE_SPELL_CHECK_API else: TRANSLATE_API
  result = parseUri(baseUrl.fmt)
  var query: seq[(string, string)]
  query.add ("isVertical", if config.isVertical: "1" else: "0")
  if config.ig.len > 0:
    query.add ("IG", config.ig)
  if config.iid.len > 0:
    query.add ("IID", "{config.iid}.{config.count}".fmt)
    config.count.inc
  result.query = encodeQuery(query)

proc buildReqBody(self: BingTranslateObj, text, src, trg: string;
    isSpellCheck = false): string =
  var body: seq[(string, string)]
  body.add ("fromLang", src)
  body.add ("text", text)
  body.add ("token", self.config.token)
  body.add ("key", self.config.key.intToStr)
  if not isSpellCheck and trg.len > 0:
    body.add ("to", trg)
  return body.encodeQuery

template newReq(): untyped =
  var headers: seq[HttpHeaderTuple]
  let url = TRANSLATE_WEBSITE.fmt()
  headers.add ("user-agent", userAgent)
  HttpClientRequestRef.new(self.session, url, headers = headers).get

proc fetchBingConfig(self: BingTranslateObj, userAgent = USER_AGENT): Future[
    BingConfig] {.async.} =
  let lock = self.config.lock
  let config = new(BingConfig)
  config.lock = lock
  try:
    var newTld: string
    var req = newReq()
    var resp: HttpClientResponseRef
    while true:
      if newTld != "":
        config.tld = newTld & "."
      resp = sendReq(req)
      if resp.status >= 300 and resp.status < 400:
        let loc = resp.headers.getString("location")
        let tldMatch = loc.match(sre r"^https?:\/\/(\w+)\.bing\.com")
        if tldMatch.isnone:
          raiseTranslateError "Bing redirect doesn't match."
        newTld = loc[tldMatch.get.captureBounds[0]]
        if req.session.isnil:
          req.session = self.session
        let res = req.redirect(parseUri(loc))
        if res.isErr:
          raiseTranslateError "Bing redirect failed."
        else:
          req = res.get
          if config.tld != newTld:
            # override host header if tld changed
            req.headers.set(HostHeader, req.address.hostname)
      else:
        break

    # defer: ensureClosed(req, resp)
    # PENDING: optional?
    for ck in resp.headers.getList("set-cookie"):
      let cks = ck.split(";")
      if len(cks) > 0:
        config.cookie.add cks[0]
        config.cookie.add "; "

    let body = bytesToString (await getBodyBytes resp)

    block:
      let igMatch = body.match(sre r"""(?s).*IG:"([^"]+)""")
      if igMatch.isnone:
        raiseTranslateError "Bing IG doesn't match."
      config.ig = body[igMatch.get.captureBounds[0]]

    block:
      let iidMatch = body.match(sre r"""(?s).*data-iid="([^"]+)""")
      if iidMatch.isnone:
        raiseTranslateError "Bing IID doesn't match."
      config.iid = body[iidMatch.get.captureBounds[0]]

    block:
      let helperMatch = body.match(sre r"(?s).*params_RichTranslateHelper\s?=\s?([^\]]+\])")
      if helperMatch.isnone:
        raiseTranslateError "Bing helper doesn't match."
      let helper = body[helperMatch.get.captureBounds[0]].parseJson
      config.key = helper[0].to(int)
      config.token = helper[1].to(string)
      config.tokenExpiryInterval = ($helper[2]).parseInt
      config.isVertical = ($helper[3]).parseBool
      config.frontDoorBotClassification = $helper[4]
      config.isSignedInOrCorporateUser = ($helper[5]).parseBool
      config.count = 0
      # exclude milliseconds
      config.tokenTs = config.key.intToStr[0..^4].parseInt.fromUnix
  except CatchableError as e:
    warn "failed to fetch global config {e[]}"
    raise e
  shallowCopy self.config[], config[]
  return config

proc validateResponse(respBody: JsonNode): bool =
  respBody.kind == JArray and
  respBody.len > 0 and
  "translations" in respBody[0] and
  respBody[0]["translations"].len > 0

proc translate*(self: BingTranslateObj, text, src, trg: string): Future[
    string] {.async.} =
  let config = self.config
  if self.isTokenExpired():
    echo "translate_bing.nim:165"
    withAsyncLock(self.config.lock):
      if self.isTokenExpired():
        discard await self.fetchBingConfig()

  let
    src = if src == "auto": "auto-detect" else: src
    uri = self.buildReqUri()
    address = self.session.getAddress(uri).get
    body = self.buildReqBody(text, src, trg)
    headers = @[
      ("user-agent", USER_AGENT),
      ("referer", TRANSLATE_WEBSITE.fmt),
      ("cookie", config.cookie),
      ("accept", "application/json"),
      ("content-type", "application/x-www-form-urlencoded"),
      ("content-length", $body.len)
      ]

  let req = HttpClientRequestRef.new(
    session = self.session, ha = address,
    meth = MethodPost,
    headers = headers, body = body.toOpenArrayByte(0, body.len - 1))

  let resp = sendReq(req)
  if resp.status != 200:
    raiseTranslateError "Bing POST request error, response code {resp.status}".fmt

  let respBody = (bytesToString (await getBodyBytes resp)).parseJson
  if not validateResponse(respBody):
    raiseTranslateError "Bing translations not found in bing response."

  return respBody[0]["translations"][0]["text"].to(string)

proc init*(_: typedesc[BingTranslateObj],
    timeout = DEFAULT_TIMEOUT): BingTranslateObj =
  let base = init(TranslateObj, timeout = timeout)
  var srv = BingTranslateObj()
  srv.kind = bing
  srv.session = base.session
  srv.maxQuerySize = 1000
  srv.config = new(BingConfig)
  srv.config.lock = newAsyncLock()
  return srv

when isMainModule:
  bt = create(BingTranslateObj)
  bt[] = init(BingTranslateObj)
  # let bc = waitFor bt[].fetchBingConfig()
  # echo bt[].isTokenExpired()
  # echo bc.tokenTs
  # echo bc.tokenExpiryInterval
  let what = "Hello, how are you?"
  echo waitFor bt[].translate(what, "auto", "it")
