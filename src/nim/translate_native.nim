import std/[monotimes, parsexml, uri, hashes]
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
  transIn: LockDeque[Query]
  transOut*: LockTable[string, string]
  transWorker*: ptr Future[void]
  rotator: TranslateRotatorPtr

proc initRotator(timeout = 3.seconds): TranslateRotatorObj =
  result.services.google = new(GoogleTranslateObj)
  result.services.google[] = init(GoogleTranslateObj)
  # result.services.add init(BingTranslateObj)
  result.services.yandex = new(YandexTranslateObj)
  result.services.yandex[] = init(YandexTranslateObj)

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
    let tkey = $(hash (id, text, src, trg))
    await transOut.popWait(tkey)

template maybeCreate*(id, tp; force: static[bool] = false) =
  when force:
    id = create(tp)
  else:
    if id.isnil:
      id = create(tp)
  reset(id[])

proc setupTranslate*() =
  transIn.setNil:
    initLockDeque[Query]()
  transOut.setNil:
    initLockTable[string, string]()

when not defined(translateProc):
  proc translateTask(id: MonoTime; text, src, trg: string) {.async.} =
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
      let id = hash (id, text, src, trg)
      transOut[$id] = translated

  proc asyncTransHandler() {.async.} =
    try:
      while true:
        let (id, text, src, trg) = await transIn.popFirstWait()
        asyncSpawn translateTask(id, text, src, trg)
    except: # If we quit we can catch defects too.
      let e = getCurrentException()[]
      warn "trans: trans handler crashed. {e}"
      quit()

  proc startTranslate*() =
    setupTranslate()
    transWorker.setNil:
      create(Future[void])
    transWorker[] = asyncTransHandler()

  proc translate*(text, src, trg: string): Future[string] {.async, raises: [].} =
    let id = getMonoTime()
    transIn.addLast (id, text, src, trg)
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
