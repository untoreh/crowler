import std/[parsexml, uri, httpcore, strformat, strutils, json]
import std/times except seconds, milliseconds
import chronos
from chronos/timer import seconds, milliseconds

import types
import utils
import translate_native_utils
import cacheduuid
import nativehttp

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
  let resp = await get(YANDEX_URI, redir=true, proxied=true)
  const errMsg =  "Yandex fetch cookies failed."
  if resp.code.int == 0:
    raiseTranslateError errMsg
  checkTrue(resp.headers.len > 0, errMsg)
  self.cookie[].setLen 0
  self.cookie[].add resp.parseCookies

proc translate*(self: YandexTranslateObj, text, src, trg: string): Future[
    string] {.async.} =
  if self.ucid.refresh:
    await self.fetchCookies()
    self.ucidStr[] = ($self.ucid.value).replace("-", "")
  let
    uri = self.buildUri
    body = self.buildBody(text, src, trg)
    headers = @[
      ("user-agent", YANDEX_USER_AGENT),
      ("cookie", self.cookie[]),
      ("accept", "application/json"),
      ("content-type", "application/x-www-form-urlencoded"),
      ("content-length", $body.len)
      ].newHttpHeaders

  # native
  let resp = await post(uri, headers, body, proxied = true)
  checkTrue(resp.body.len > 0, "yandex: empty body")
  if resp.code != Http200:
    raiseTranslateError "Yandex POST request error, response code {resp.code}".fmt
  let respJson = (resp.body).parseJson

  if respJson.kind != JObject or "text" notin respJson or respJson["text"].len == 0:
    raiseTranslateError "Yandex respone has no translation."
  return respJson["text"][0].to(string)

proc init*(_: typedesc[YandexTranslateObj]): YandexTranslateObj =
  let base = init(TranslateObj)
  var srv = YandexTranslateObj()
  srv.kind = yandex
  srv.maxQuerySize = base.maxQuerySize
  srv.ucid = CachedUUID()
  srv.ucidStr = new(string)
  srv.cookie = new(string)
  return srv

when isMainModule:
  initHttp()
  ydx = create(YandexTranslateObj)
  ydx[] = init(YandexTranslateObj)
  let s = "This is a good day."
  echo waitFor ydx[].translate(s, "en", "it")
