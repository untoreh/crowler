import std/[parsexml, streams, uri]
import chronos/apps/http/httpclient
import chronos

from cfg import PROXY_EP
import types
import utils
# from types import LockTable
# from utils import warn

type TranslateError = object of ValueError
type
  GoogleTranslateObj = object
    session: HTtpSessionRef
  GoogleTranslate = ref GoogleTranslateObj
  Query = tuple[text: string, src: string, trg: string]
  GoogleTranslatePtr = ptr GoogleTranslateObj

var transThread: Thread[void]

const
  apiUrl = "https://translate.google.com/m"
  apiUri = apiUrl.parseUri
  targetEl1 = "div"
  targetClass1 = "t0"
  targetClass2 = "result-container"

var
  transIn*: ptr AsyncQueue[Query]
  transOut*: LockTable[Query, string]
  transEvent*: ptr AsyncEvent
  transLock*: ptr AsyncLock
  gt*: GoogleTranslatePtr

proc queryUrl(data, src, trg: string): Uri =
  var uri = apiUri
  var query: seq[(string, string)]
  query.add ("q", data)
  query.add ("sl", src)
  query.add ("tl", trg)
  uri.query = encodeQuery(query)
  return uri


proc init(gto: var GoogleTranslateObj) =
  gto.session =
    new(HttpSessionRef,
    connectTimeout = 7.seconds,
    headersTimeout = 7.seconds,
    proxyTimeout = 7.seconds,
    proxy = PROXY_EP,
    flags = {NewConnectionAlways}
    # proxyAuth=proxyAuth("user", "pass")
    )

proc doReq(self: GoogleTranslateObj, uri: Uri, retries = 10,
    backoff = 250.milliseconds): Future[string] {.async.} =
  var backoff = backoff
  for r in 0..<retries:
    try:
      let resp = waitfor self.session.fetch(uri)
      if resp.status != 200:
        continue
      return bytesToString resp.data
    except CatchableError:
      echo getCurrentException()[]
      await sleepAsync(backoff)
      backoff += backoff
      continue
  raise newException(TranslateError, "Translation request failed.")


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
  defer: close(x)
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
    raise newException(TranslateError, "Translation string exceeds max length of 5000 bytes.")
  let uri = queryUrl(text[0..<min(text.len, 5000)], "en", "it")
  let html = await self.doReq(uri)
  result = getTranslation(html)
  if result.len == 0:
    raise newException(TranslateError, "Translation was empty.")

proc translateTask(text, src, trg: string) {.async.} =
  let query = (text: text, src: src, trg: trg)
  try:
    let translated = await gt[].translate(text, src, trg)
    transOut[query] = translated
  except CatchableError as e:
    transOut[query] = ""
    warn "trans: job failed, {e.msg}."
  transEvent[].fire; transEvent[].clear

proc translate*(text, src, trg: string): Future[string] {.async.} =
  let tkey = (text, src, trg)
  await transIn[].put(tkey)
  while true:
    await wait(transEvent[])
    if tkey in transOut:
      discard transOut.pop(tkey, result)
      break

proc asyncTransHandler() {.async.} =
  try:
    doassert not gt.isnil
    while true:
      let (text, src, trg) = await transIn[].get()
      asyncSpawn translateTask(text, src, trg)
  except: # If we quit we can catch defects too.
    let e = getCurrentException()[]
    warn "trans: trans handler crashed. {e}"
    quit()

proc transHandler() = waitFor asyncTransHandler()

proc startTranslator*() =
  createThread(transThread, transHandler)
  transIn = create(AsyncQueue[Query])
  transIn[] = newAsyncQueue[Query](256)
  transOut = initLockTable[Query, string]()
  transEvent = create(AsyncEvent)
  transEvent[] = newAsyncEvent()
  transLock = create(AsyncLock)
  transLock[] = newAsyncLock()
  gt = create(GoogleTranslateObj)
  init(gt[])
  # gt = new(GoogleTranslate)

when isMainModule:
#   let gt = new(GoogleTranslate)
  startTranslator()
  let text = """This was a fine day."""
  echo waitFor translate(text[0..<min(text.len, 5000)], "en", "it")
#   echo waitFor gt.translate(text[0..<min(text.len, 5000)], "en", "it")
#   echo waitFor gt.translate(text[0..<min(text.len, 5000)], "en", "it")
#   echo waitFor gt.translate(text[0..<min(text.len, 5000)], "en", "it")
