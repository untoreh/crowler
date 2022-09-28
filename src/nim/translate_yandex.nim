import std/[parsexml, streams, uri, httpcore, strformat, strutils, json]
import std/times except seconds, milliseconds
import chronos/apps/http/httpclient
import chronos
from chronos/timer import seconds, milliseconds

from cfg import PROXY_EP
import types
import utils
import translate_native_utils
import cacheduuid

const
  # YANDEX_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.88 Safari/537.36"
  YANDEX_USER_AGENT = "ru.yandex.translate/3.20.2024"
  YANDEX_URI = "https://translate.yandex.ru:443".parseUri
  YANDEX_API = "https://translate.yandex.net/api/v1/tr.json/translate".parseUri
  YANDEX_EXPIRATION = 360.seconds

type
  YandexTranslateObj* = object of TranslateObj
    ucid: CachedUUID
    ucidStr: ref string
    cookie: ref string
  YandexTranslate* = ref YandexTranslateObj
  YandexTranslatePtr* = ptr YandexTranslateObj

var ydx*: YandexTranslatePtr

proc buildUri(self: YandexTranslateObj): Uri =
  result = YANDEX_API
  var query: seq[(string, string)]
  query.add ("ucid", self.ucidStr[])
  query.add ("srv", "android")
  query.add ("format", "text")
  result.query = encodeQuery(query)

proc buildBody(self: YandexTranslateObj, text, src, trg: string): string =
  var body: seq[(string, string)]
  body.add ("text", text)
  body.add ("lang", if src.len > 0: "{src}-{trg}".fmt else: trg)
  return body.encodeQuery

proc fetchCookies(self: YandexTranslateObj) {.async.} =
  var
    req = new(HttpClientRequestRef, self.session, YANDEX_URI.getAddress.get)
    resp: HttpClientResponseRef
    prevLoc: string
  for _ in 0..<10:
    try:
      resp = req.sendReq
      if resp.status >= 300 and resp.status < 400:
        let loc = resp.headers.getString("location")
        let locUri = parseUri(loc)
        if loc != prevLoc:
          if req.session.isnil:
            req.session = self.session
          let res = req.redirect(locUri)
          if res.isErr:
            raiseTranslateError "Yandex redirect failed."
          else:
            req = res.get
            # req.headers.set HostHeader, loc
            prevLoc = loc
        else:
          break
      else:
        break
    except CatchableError:
      ensureClosed(req, resp)
      req = new(HttpClientRequestRef, self.session, YANDEX_URI.getAddress.get)
  defer: ensureClosed(req, resp)
  if resp.isnil:
    raiseTranslateError "Yandex fetch cookies failed."
  self.cookie[].setLen 0
  self.cookie[].add resp.parseCookies

proc translate*(self: YandexTranslateObj, text, src, trg: string): Future[
    string] {.async.} =
  if self.ucid.refresh:
    await self.fetchCookies()
    self.ucidStr[] = ($self.ucid.value).replace("-", "")
  let
    uri = self.buildUri
    address = self.session.getAddress(uri).get
    body = self.buildBody(text, src, trg)
    headers = @[
      ("user-agent", YANDEX_USER_AGENT),
      ("cookie", self.cookie[]),
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
    raiseTranslateError "Yandex POST request error, response code {resp.status}".fmt

  let respJson = (bytesToString (await getBodyBytes resp)).parseJson
  if respJson.kind != JObject or "text" notin respJson or respJson["text"].len == 0:
    raiseTranslateError "Yandex respone has no translation."
  return respJson["text"][0].to(string)

proc init*(_: typedesc[YandexTranslateObj],
    timeout = DEFAULT_TIMEOUT): YandexTranslateObj =
  let base = init(TranslateObj, timeout = timeout)
  var srv = YandexTranslateObj()
  srv.kind = yandex
  srv.session = base.session
  srv.maxQuerySize = base.maxQuerySize
  srv.ucid = CachedUUID()
  srv.ucidStr = new(string)
  srv.cookie = new(string)
  return srv

when isMainModule:
  ydx = create(YandexTranslateObj)
  ydx[] = init(YandexTranslateObj)
  let s = "This is a good day."
  echo waitFor ydx[].translate(s, "en", "it")
