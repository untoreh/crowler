import std/[monotimes, parsexml, uri, hashes]
import threading/channels
import chronos

import
  types,
  utils,
  translate_native_utils,
  translate_google,
  translate_bing,
  translate_yandex,
  sharedqueue


const enabledTranslators = [google, yandex]
type
  TranslateRotatorObj = object
    services: tuple[google: GoogleTranslate, bing: BingTranslate,
        yandex: YandexTranslate]
    idx: int
  TranslateRotatorPtr = ptr TranslateRotatorObj

var
  transIn: AsyncPColl[ptr Query]
  transWorker*: ptr Future[void]
  rotator: TranslateRotatorPtr
when not defined(translateProc):
  var transOut*: AsyncTable[ptr Query, bool]
else:
  var transOut*: AsyncTable[int, ptr string]

proc hash(q: ptr Query): Hash =
  hash((q.id, q.text, q.src, q.trg))

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
    discard await transOut.pop(q.addr)
    defer: free(v)
    if v.isnil:
      ""
    else:
      v[]

proc setupTranslate*() =
  transIn.notNil:
    delete(transIn)
  transIn = newAsyncPColl[ptr Query]()
  transOut.setNil:
    newAsyncTable[when not defined(translateProc): ptr Query else: int, bool]()

when not defined(translateProc):
  proc translateTask(q: ptr Query) {.async.} =
    var
      tries: int
      success: bool
      translated: ref string
    new(translated)
    try:
      for _ in 0..3:
        try:
          translated[].add await callService(q.text, q.src, q.trg)
          if translated[].len == 0:
            continue
          success = true
          break
        except CatchableError:
          if tries > 3:
            break
          tries.inc
    except CatchableError:
      warn "trans: job failed, {q.src} -> {q.trg}."
    finally:
      q.trans = translated
      transOut[q] = true

  proc asyncTransHandler() {.async.} =
    try:
      while true:
        # let qPtr = await transIn.popFirstWait()
        let q = await transIn.pop()
        asyncSpawn translateTask(q)
    except: # If we quit we can catch defects too.
      let e = getCurrentException()[]
      warn "trans: trans handler crashed. {e}"
      quitl()

  proc startTranslate*() =
    setupTranslate()
    transWorker.setNil:
      create(Future[void])
    if not transWorker[].isnil:
      waitFor transWorker[]
    transWorker[] = asyncTransHandler()

  proc translate*(text, src, trg: string): Future[string] {.async, raises: [].} =
    var q: Query
    q.id = getMonoTime()
    q.src = src
    q.trg = trg
    q.text = text
    transIn.add q.addr
    discard await transOut.pop(q.addr)
    result =
      if q.trans.isnil: ""
      else: q.trans[]

when isMainModule:
  proc test() {.async.} =
    var futs: seq[Future[string]]
    var text = """This was a fine day."""
    futs.add translate(text, "en", "it")
    text = """This was better plan."""
    futs.add translate(text, "en", "it")
    text = """The sun in the sky is yellow."""
    futs.add translate(text, "en", "it")
    for f in futs:
      echo await f
  import nativehttp
  initHttp()
  startTranslate()
  waitFor test()
