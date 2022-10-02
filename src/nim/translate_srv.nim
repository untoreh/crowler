import nimpy,
       os,
       osproc,
       sets,
       sugar,
       strutils,
       strformat,
       tables,
       macros,
       locks,
       chronos

import
  cfg,
  types,
  translate_types,
  utils,
  quirks,
  pyutils

when defined(translateProc):
  import translate_proc
  export translate_proc

const nativeTranslator* {.booldefine.}: bool = true

static: echo "loading translate_srv"

proc ensurePy(srv: service): PyObject =
  if not pygil.locked:
    warn "ensurepy: calling python without python lock (should already be locked)"
  try:
    return case srv:
      of deep_translator:
        pyImport(cstring($srv))
      of base_translator:
        pyImport(cstring($srv))
      else:
        raise newException(OSError, fmt"{srv} is not python based.")
  except Exception as e:
    if "ModuleNotFoundError" in e.msg or "No module named" in e.msg:
      if getEnv("VIRTUAL_ENV", "") != "":
        let sys = pyImport("sys")
        info "translate: installing {srv} with pip, syspat: {sys.path}"
        let res = execCmd(fmt"pip install {srv}")
        if res != 0:
          raise newException(OSError, fmt"Failed to install {srv}, check your python virtual environment.")
      else:
        raise newException(OSError, "Can't install modules because not in a python virtual env.")
    else:
      raise e


template pySafeCall(code: untyped): untyped =
  logall "pysafe: acquiring lock"
  # {.locks: [pyGilLock].}:
  try:
    await pygil.acquire()
    logall "pysafe: lock acquired"
    code
  except CatchableError:
    let e {.inject.} = getCurrentException()[]
    warn "pysafe: Failed with exception...{e}"
  finally:
    logall "pysafe: releasing lock"
    pygil.release()
  logall "pysafe: lock released"

proc getProxies(srv: service = deep_translator): auto =
  case srv:
    of deep_translator:
      if USE_PROXIES:
        debug "trsrv: enabling proxies with endpoint {PROXY_EP}"
        {"https": PROXY_EP, "http": PROXY_EP}.to_table
      else:
        {"https": "", "http": ""}.to_table
    else:
      {"https": "", "http": ""}.to_table


proc initSlator*(srv: service = default_service, provider: string = "", source: Lang = SLang,
        targets: HashSet[Lang] = TLangs): Translator =
  new(result)
  if srv != native:
    syncPyLock:
      result.pymod = ensurePy(srv)
      result.pycls = result.pymod.getattr("Translator")()
      result.pytranslate = result.pycls.translate
      result.name = base_translator
      # result.provider = ""
  else:
    result.name = native

let
  srv = when nativeTranslator:
          import translate_native
          export translate_native
          native
        else:
          base_translator
  slatorObj = initSlator(srv)
  slator* = slatorObj.unsafeAddr

# when not nativeTranslator:
#   slatorObj = initTranslator()
#   slator = slatorObj.unsafeAddr
# else:
#   slator = create(Translator)
#   slator[] = Translator()
#   slator[].name = "native"
#   export translate_native

proc doJob(src: string, lang: langPair): PyObject {.withLocks: [pyGil].} =
  # if unlikely(slator.pytranslate.isnil):
  #   doassert not slator.isnil
  #   doassert not slator.pycls.isnil
  #   slator.pytranslate = slator.pycls.translate
  result = pySched[].apply(slator.pytranslate, src, lang.trg)

proc callTranslatorPy*(src: string, lang: langPair): Future[string] {.async, gcsafe.} =
  try:
    var rdy: bool
    var res, j: PyObject
    pySafeCall:
      debug "tfun: applying function with src ({src.len})"
      j = doJob(src, lang)
      debug "tfun: applied f ({src.len})"
    while true:
      pySafeCall:
        logall "tfun: waiting for translation {rdy}, {lang}, {j.isnil}"
        rdy = j.ready().to(bool)
      if rdy:
        debug "tfun: getting translation value job"
        pySafeCall: res = j.get()
        break
      await sleepAsync(250.milliseconds)
    pySafecall:
      debug "tfun: checking response"
      if (not res.isnil) and (not ($res in ["<NULL>", "None"])):
        debug "tfun: returning translation"
        let v = res.to(string)
        result = v
      else:
        debug "tfun: no translation found"
        result = ""
  except Exception as e:
    raise newException(ValueError, fmt"Translation failed with error: {e.msg}")

proc callTranslatorNative*(src: string, lang: langPair): Future[
    string] {.async.} =
  return await translate(src, lang.src, lang.trg)

const callTranslator* =
  when nativeTranslator:
    callTranslatorNative
  else:
    callTranslatorPy


# /////////// THIS SHOULD BE DONE PYTHON SIDE ///////////
#
# proc setPairFun*(pair: langPair) =
#     case slator.name:
#         of deep_translator:
#             let provfn = slator.py.getattr(slator[].provider)
#             slator.tr[pair] = provfn(source = pair.src, target = pair.trg, proxies = getProxies(deep_translator))
#         of base_translator:
#             discard
# discard pybi.exec: """
# from time import sleep
# def tryWrapper(fn, n: int, def_val=""):
#     def wrappedFn(*args, tries=1, e=None):
#         if tries < n:
#             try:
#                 return fn(*args)
#             except Exception as e:
#                 sleep(tries)
#                 return wrappedFn(*args, tries=tries+1, e=e)
#         else:
#             print("wrapped function reached max tries, last exception was: ", e)
#             return def_val
#     return wrappedFn
# """
# let tryWrapper = pyglo["tryWrapper"]

# proc trywrapPyFunc*(fn: PyObject, tries = 3, defVal = ""): PyObject =
#     debug "trywrap: returning try wrapper {tries}"
#     return tryWrapper(fn, tries, defVal)

# case srv:
  # of deep_translator:
  #     result.py = py
  #     result.apis = toHashSet(["GoogleTranslator", "LingueeTranslator",
  #             "MyMemoryTranslator"]) # "single_detection", "batch_detection"
  #     result.name = srv
  #     let prov = if provider == "": "GoogleTranslator" else: provider
  #     assert prov in result.apis
  #     result.provider = prov
  #     let
  #         provFn = result.py.getattr(prov)
  #         src = source.code
  #         cls = provFn()
  #         proxies = getProxies(srv)
  #     for l in targets:
  #         for suplang in cls.getAttr("_languages").values():
  #             let sl = suplang.to(string)
  #             if l.code in sl:
  #                 result.tr[(src, sl)] = provFn(source = src, target = sl, proxies = proxies)
