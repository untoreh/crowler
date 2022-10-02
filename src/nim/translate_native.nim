import std/[parsexml, streams, uri, hashes]
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
  transOut*: LockTable[string, string]
  transEvent*: ptr AsyncEvent
  transThread*: Thread[void]
  transLock*: Lock
  rotator: TranslateRotatorPtr

proc initRotator(timeout = 3.seconds): TranslateRotatorObj =
  result.services.google = new(GoogleTranslateObj)
  result.services.google[] = init(GoogleTranslateObj, timeout = timeout)
  # result.services.add init(BingTranslateObj, timeout=timeout)
  result.services.yandex = new(YandexTranslateObj)
  result.services.yandex[] = init(YandexTranslateObj, timeout = timeout)

proc callService*(text, src, trg: string): Future[string] {.async.} =
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

template waitTrans*(): string =
  block:
    var event: AsyncEvent
    var res: string
    let tkey = $(hash (text, src, trg))
    while true:
      withLock(transLock):
        event = transEvent[]
      await event.wait
      if tkey in transOut:
        discard transOut.pop(tkey, res)
        break
    res

template setNil*(id, val) =
  if id.isnil:
    id = val

template ifNil*(id, val) =
  if id.isnil:
    val

template maybeCreate*(id, tp; force: static[bool] = false) =
  when force:
    id = create(tp)
  else:
    if id.isnil:
      id = create(tp)
  reset(id[])

proc setupTranslate*() =
  transIn.setNil:
    create(AsyncQueue[Query])
  reset(transIn[])
  transIn[] = newAsyncQueue[Query](1024 * 16)
  transOut.setNil:
    initLockTable[string, string]()
  transEvent.setNil:
    create(AsyncEvent)
  transEvent[] = newAsyncEvent()

when not defined(translateProc):
  proc translateTask(text, src, trg: string) {.async.} =
    var tries: int
    var success: bool
    var translated: string
    try:
      for _ in 0..3:
        try:
          translated.add await callService(text, src, trg)
          if translated.len == 0:
            continue
          success = true
          break
        except CatchableError:
          if tries > 3:
            break
          tries.inc
    except CatchableError:
      warn "trans: job failed, {src} -> {trg}."
    finally:
      let id = hash (text, src, trg)
      transOut[$id] = translated
      withLock(transLock):
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

  proc startTranslate*() =
    setupTranslate()
    createThread(transThread, transHandler)

  proc translate*(text, src, trg: string): Future[string] {.async, raises: [].} =
    await transIn[].put (text, src, trg)
    return waitTrans()

when isMainModule:
  proc test() {.async.} =
    var text = """This was a fine day."""
    echo await translate(text, "en", "it")
    text = """This was better plan."""
    echo await translate(text, "en", "it")
    text = """The sun in the sky is yellow."""
    echo await translate(text, "en", "it")
  startTranslate()
  # waitFor test()
