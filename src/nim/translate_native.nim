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


const enabledTranslators = [google, yandex]
type
  TranslateRotatorObj = object
    services: tuple[google: GoogleTranslate, bing: BingTranslate,
        yandex: YandexTranslate]
    idx: int
  TranslateRotatorPtr = ptr TranslateRotatorObj
  AnyTranslate = GoogleTranslate | BingTranslate | YandexTranslate

var
  transIn: ptr AsyncQueue[Query]
  transOut: LockTable[Query, string]
  transEvent: ptr AsyncEvent
  transThread: Thread[void]
  rotator: TranslateRotatorPtr

proc initRotator(timeout = 3.seconds): TranslateRotatorObj =
  result.services.google = new(GoogleTranslateObj)
  result.services.google[] = init(GoogleTranslateObj, timeout = timeout)
  # result.services.add init(BingTranslateObj, timeout=timeout)
  result.services.yandex = new(YandexTranslateObj)
  result.services.yandex[] = init(YandexTranslateObj, timeout = timeout)

proc callService(text, src, trg: string): Future[string] {.async.} =
  if unlikely(rotator.isnil):
    rotator = create(TranslateRotatorObj)
    rotator[] = initRotator()
  if rotator.idx >= enabledTranslators.len:
    rotator.idx = 0
  let kind = enabledTranslators[rotator.idx]
  template callTrans(srv: untyped): untyped =
    if text.len > srv.maxQuerySize:
      let s {.inject.} = srv
      warn "trans: text of size {text.len} exceeds maxQuerysize of {s.maxQuerySize} for service {s.kind}."
      ""
    else:
      await srv[].translate(text, src, trg)
  try:
    result =
      case kind:
        of google:
          callTrans rotator.services.google
        of bing:
          callTrans rotator.services.bing
        of yandex:
          callTrans rotator.services.yandex
  finally:
    rotator.idx.inc

proc translateTask(text, src, trg: string) {.async.} =
  let query = (text: text, src: src, trg: trg)
  var tries: int
  var success: bool
  try:
    for _ in 0..3:
      try:
        let translated = await callService(text, src, trg)
        if translated.len == 0:
          continue
        transOut[query] = translated
        transEvent[].fire
        transEvent[].clear
        success = true
        return
      except CatchableError:
        if tries > 3:
          break
        tries.inc
  except Exception as e:
    echo e[]
    warn "trans: job failed, {src} -> {trg}."
  finally:
    if unlikely(not success):
      transOut[query] = ""
      transEvent[].fire
      transEvent[].clear

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
    await transEvent[].wait
    if tkey in transOut:
      discard transOut.pop(tkey, res)
      break
  return res

proc startTranslator*() =
  transIn = create(AsyncQueue[Query])
  transIn[] = newAsyncQueue[Query](1024 * 16)
  transOut = initLockTable[Query, string]()
  transEvent = create(AsyncEvent)
  transEvent[] = newAsyncEvent()
  createThread(transThread, transHandler)

when isMainModule:
  proc test() {.async.} =
    var text = """This was a fine day."""
    discard await translate(text, "en", "it")
    text = """This was better plan."""
    discard await translate(text, "en", "it")
    text = """The sun in the sky is yellow."""
    discard await translate(text, "en", "it")
  startTranslator()
  waitFor test()
