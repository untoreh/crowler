import std/[parsexml, streams, uri]
import chronos/apps/http/httpclient
import chronos

import
  types,
  utils,
  translate_native_utils,
  translate_google,
  translate_bing,
  translate_yandex

type
  TranslateRotatorObj = object
    services: seq[TranslateObj]
    idx: int
  TranslateRotatorPtr = ptr TranslateRotatorObj

var
  transIn*: ptr AsyncQueue[Query]
  transOut*: LockTable[Query, string]
  transEvent*: ptr AsyncEvent
  transThread: Thread[void]
  rotator: TranslateRotatorPtr

proc initRotator(timeout = 3.seconds): TranslateRotatorObj =
  result.services.add init(GoogleTranslateObj, timeout=timeout)
  # result.services.add init(BingTranslateObj, timeout=timeout)
  result.services.add init(YandexTranslateObj, timeout=timeout)

proc getService(): TranslateObj =
  if unlikely(rotator.isnil):
    rotator = create(TranslateRotatorObj)
    rotator[] = initRotator()
  if rotator.idx >= rotator.services.len:
    rotator.idx = 0
  result = rotator.services[rotator.idx]
  rotator.idx.inc

proc translateTask(text, src, trg: string) {.async.} =
  let query = (text: text, src: src, trg: trg)
  var tries: int
  var success: bool
  try:
    for _ in 0..3:
      try:
        let srv = getService()
        if text.len > srv.maxQuerySize:
          warn "trans: text of size {text.len} exceeds maxQuerysize of {srv.maxQuerySize} for service {srv}."
          continue
        let translated = await srv.translateImpl(text, src, trg)
        transOut[query] = translated
        transEvent[].fire; transEvent[].clear
        success = true
        return
      except CatchableError:
        if tries > 3:
          break
        tries.inc
  except:
    warn "trans: job failed, {src} -> {trg}."
  finally:
    if unlikely(not success):
      transOut[query] = ""
      transEvent[].fire; transEvent[].clear

proc asyncTransHandler() {.async.} =
  try:
    while true:
      let (text, src, trg) = await transIn[].get()
      asyncSpawn translateTask(text, src, trg)
  except: # If we quit we can catch defects too.
    let e = getCurrentException()[]
    warn "trans: trans handler crashed. {e}"
    quit()

proc transHandler() = waitFor asyncTransHandler()

proc translate*(text, src, trg: string): Future[string] {.async, raises: [].} =
  var res: string
  let tkey = (text, src, trg)
  await transIn[].put(tkey)
  while true:
    await wait(transEvent[])
    if tkey in transOut:
      discard transOut.pop(tkey, res)
      break
  return res

proc startTranslator*() =
  createThread(transThread, transHandler)
  transIn = create(AsyncQueue[Query])
  transIn[] = newAsyncQueue[Query](1024 * 16)
  transOut = initLockTable[Query, string]()
  transEvent = create(AsyncEvent)
  transEvent[] = newAsyncEvent()

when isMainModule:
  proc test() {.async.} =
    var text = """This was a fine day."""
    discard await translate(text, "en", "it")
    echo "translate_native.nim:94"
    text = """This was better plan."""
    echo "translate_native.nim:96"
    discard await translate(text, "en", "it")
    echo "translate_native.nim:98"
    text = """The sun in the sky is yellow."""
    discard await translate(text, "en", "it")
  startTranslator()
  waitFor test()
