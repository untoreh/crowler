import std/[parsexml, streams, uri]
import chronos

import types
import utils
import translate_native_utils
import nativehttp

type
  GoogleTranslateObj* = object of TranslateObj
  GoogleTranslate* = ref GoogleTranslateObj
  GoogleTranslatePtr = ptr GoogleTranslateObj

const
  apiUrl = "https://translate.google.com/m"
  apiUri = apiUrl.parseUri
  targetEl1 = "div"
  targetClass1 = "t0"
  targetClass2 = "result-container"

proc queryUrl(data, src, trg: string): Uri =
  var uri = apiUri
  var query: seq[(string, string)]
  query.add ("q", data)
  query.add ("sl", src)
  query.add ("tl", trg)
  uri.query = encodeQuery(query)
  return uri

template addText() =
  while true:
    next(x)
    case x.kind:
      of xmlCharData:
        result.add x.charData
      of xmlElementEnd, xmlEof:
        return
      else:
        continue

proc getTranslation(resp: string): string =
  ## Parses the response html page and get the translation
  var x: XmlParser
  let stream = newStringStream(resp)
  open(x, stream, "")
  defer:
    close(x)
    close(stream)
  while true:
    next(x)
    case x.kind:
      of xmlElementOpen:
        if x.elementName == targetEl1:
          while true:
            next(x)
            case x.kind:
              of xmlAttribute:
                if x.attrKey == "class" and
                  (x.attrValue == targetClass1 or x.attrValue == targetClass2):
                  addText()
              of xmlEof:
                return
              else:
                continue
      of xmlEof:
        break
      else:
        continue

proc translate*(self: GoogleTranslateObj, text, src, trg: string): Future[
    string] {.async.} =
  if text.len == 0:
    return
  elif text.len > 5000:
    raiseTranslateError "Translation string exceeds max length of 5000 bytes."
  let uri = queryUrl(text, src, trg)
  let resp = await get(uri, proxied = true)
  if resp.body.len == 0:
    raiseTranslateError "Translation was empty."
  result = getTranslation(resp.body)

proc init*(_: typedesc[GoogleTranslateObj]): GoogleTranslateObj =
  let base = init(TranslateObj)
  var srv = GoogleTranslateObj()
  srv.kind = google
  srv.maxQuerySize = base.maxQuerySize
  return srv

template wrap(code) =
  try: code
  except: discard

