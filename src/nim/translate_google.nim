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

var gt*: GoogleTranslatePtr

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

when isMainModule:
  initHttp()
  gt = create(GoogleTranslateObj)
  gt[] = init(GoogleTranslateObj)
  var text = """This was a fine day."""
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Buddy please help."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Not right now, maybe tomorrow."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "The greatest glory in living lies not in never falling, but in rising every time we fall."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "The way to get started is to quit talking and begin doing"
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Your time is limited, so don't waste it living someone else's life"
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "If life were predictable it would cease to be life, and be without flavor"
  wrap echo waitFor gt[].translate(text, "en", "it")
  import os
  sleep(100000)
