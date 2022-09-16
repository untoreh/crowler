import std/[parsexml, streams, uri, httpcore, nre, strformat, strutils, json]
import std/times except seconds, milliseconds
# from std/times import nil
# from std/times import getTime, fromUnix, Time, `-`
import chronos/apps/http/httpclient
import chronos
from chronos/timer import seconds, milliseconds

from cfg import PROXY_EP
import types
import utils

type TranslateError = object of ValueError
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
  BingTranslateObj = object
    session: HTtpSessionRef
    config: BingConfig
  BingTranslate = ref BingTranslateObj
  Query = tuple[text: string, src: string, trg: string]
  BingTranslatePtr = ptr BingTranslateObj

const
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.88 Safari/537.36"
  # USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko)"
  TRANSLATE_API_ROOT = "https://{config.tld}bing.com" # this is formatted, requires `var config: BingConfig`
  TRANSLATE_WEBSITE = TRANSLATE_API_ROOT & "/translator"
  TRANSLATE_API = TRANSLATE_API_ROOT & "/ttranslatev3"
  TRANSLATE_SPELL_CHECK_API = TRANSLATE_API_ROOT & "/tspellcheckv3"

proc raiseTranslateError(msg: string) =
  raise newException(TranslateError, msg)

var bt*: BingTranslatePtr
proc init(bto: var BingTranslateObj) =
  bto.session =
    new(HttpSessionRef,
    connectTimeout = 5.seconds,
    headersTimeout = 5.seconds,
    proxyTimeout = 5.seconds,
    maxRedirections = 10,
    # proxy = PROXY_EP,
    # flags = {NewConnectionAlways}
    # proxyAuth=proxyAuth("user", "pass")
    )
  bto.config = new(BingConfig)

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

template sendReq(req): HttpClientResponseRef =
  block:
    var
      req = req
      resp: HttpClientResponseRef
      backoff = 250.milliseconds
      tries = 0
    while true:
      try:
        resp = await req.send()
        break
      except CatchableError:
        if tries > 10:
          break
        await sleepAsync(backoff)
        tries.inc
        backoff += backoff
        req = req.redirect(req.address).get
    resp

proc fetchBingConfig(self: BingTranslateObj, userAgent = USER_AGENT): Future[
    BingConfig] {.async.} =
  let config = new(BingConfig)
  try:
    var newTld: string
    var req = newReq()
    var resp: HttpClientResponseRef
    while true:
      if newTld != "":
        config.tld = newTld & "."
      resp = sendReq(req)
      # resp = await req.send()
      if resp.status >= 300 and resp.status < 400:
        let loc = resp.headers.getString("location")
        let tldMatch = loc.match(sre r"^https?:\/\/(\w+)\.bing\.com")
        if tldMatch.isnone:
          raiseTranslateError "Bing redirect doesn't match."
        newTld = loc[tldMatch.get.captureBounds[0]]
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

proc translateBing*(text, src, trg: string): Future[string] {.async.} =
  let bt = bt[]
  let config = bt.config
  if bt.isTokenExpired():
    discard await bt.fetchBingConfig()

  let
    src = if src == "auto": "auto-detect" else: src
    uri = bt.buildReqUri()
    address = bt.session.getAddress(uri).get
    body = bt.buildReqBody(text, src, trg)
    headers = @[
      ("user-agent", USER_AGENT),
      ("referer", TRANSLATE_WEBSITE.fmt),
      ("cookie", config.cookie),
      ("accept", "application/json"),
      ("content-type", "application/x-www-form-urlencoded"),
      ("content-length", $body.len)
      ]

  let req = HttpClientRequestRef.new(
    session = bt.session, ha = address,
    meth = MethodPost,
    headers = headers, body = body.toOpenArrayByte(0, body.len - 1))

  let resp = sendReq(req)
  if resp.status != 200:
    raiseTranslateError "Bing POST request error, response code {resp.status}".fmt

  let respBody = (bytesToString (await getBodyBytes resp)).parseJson
  if respBody.len == 0 or "translations" notin respBody[0] or respBody[0][
      "translations"].len == 0:
    raiseTranslateError "Bing translations not found in bing response."

  return respBody[0]["translations"][0]["text"].to(string)

when isMainModule:
  bt = create(BingTranslateObj)
  init(bt[])
  # let bc = waitFor bt[].fetchBingConfig()
  # echo bt[].isTokenExpired()
  # echo bc.tokenTs
  # echo bc.tokenExpiryInterval
  let what = "Hello, how are you?"
  echo waitFor translateBing(what, "auto", "it")
