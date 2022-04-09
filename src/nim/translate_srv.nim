import nimpy,
       os,
       osproc,
       sets,
       sugar,
       strutils,
       strformat,
       tables,
       macros,
       locks

from nimpy/py_types import PPyObject
from nimpy {.all.} import newPyObject

import
    cfg,
    types,
    translate_types,
    utils,
    quirks

static: echo "loading translate_srv"

let pybi = pyBuiltinsModule()
let pyGlo = pyGlobals()
var tFuncCache* {.threadvar.}: ptr Table[(service, langpair), TFunc]

proc initTFuncCache*() =
    if tFuncCache.isnil:
        tFuncCache = create(Table[(service, langpair), TFunc])

proc ensurePy(srv: service): PyObject =
    try:
        return pyImport($srv)
    except Exception as e:
        if "ModuleNotFoundError" in e.msg:
            if getEnv("VIRTUAL_ENV", "") != "":
                let res = execCmd(fmt"pip install {srv}")
                if res != 0:
                    raise newException(OSError, fmt"Failed to install {srv}, check your python virtual environment.")
            else:
                raise newException(OSError, "Can't install modules because not in a python virtual env.")
        else:
            raise e

discard pybi.exec: """
from time import sleep
def tryWrapper(fn, n: int, def_val=""):
    def wrappedFn(*args, tries=1, e=None):
        if tries < n:
            try:
                return fn(*args)
            except Exception as e:
                sleep(tries)
                return wrappedFn(*args, tries=tries+1, e=e)
        else:
            print("wrapped function reached max tries, last exception was: ", e)
            return def_val
    return wrappedFn
"""
discard relpyImport("../py/config")
let
    tryWrapper = pyglo["tryWrapper"]
    pySched = relpyImport("../py/scheduler")
    pySchedPtr = pySched.privateRawPyObj


discard pySched.initPool()

proc trywrapPyFunc(fn: PyObject, tries = 3, defVal = ""): PyObject =
    return tryWrapper(fn, tries, defVal)

template pySafeCall(code: untyped): untyped =
    slator.lock.acquire
    code
    slator.lock.release

proc deepTranslatorTfun(lang: langPair, slator: Translator): TFunc =
    # NOTE: using `slator` inside the closure is fine since it always outlives the closure
    result = proc(src: string): string =
        try:
            var
                res: PyObject
                rdy: bool
            pySafeCall:
                debug "tfun: applying function with src ({src.len})"
                let pyf = slator.tr[lang].getattr("translate").trywrapPyFunc
                let j = pySched.apply(pyf, src)
                debug "tfun: applied f ({src.len})"
            while true:
                pySafeCall:
                    discard j.wait(cfg.TRANSLATION_TIMEOUT)
                    rdy = j.ready().to(bool)
                    debug "tfun: waiting for translation {rdy}, {lang}"
                if rdy:
                    debug "tfun: getting translation value"
                    pySafeCall: res = j.get()
                    break
            # # debug "res: {$res}"
            pySafecall:
                if not ($res in ["<NULL>", "None"]):
                    debug "tfun: returning translation"
                    let v = res.to(string)
                    result = v
                else:
                    debug "tfun: no translation found"
                    result = ""
        except Exception as e:
            raise newException(ValueError, "Translation failed with error: {e.msg}")


proc getTfun*(lang: langPair, slator: Translator): TFunc =
    try:
        result = tFuncCache[][(slator.name, lang)]
    except:
        result = case slator.name:
            of deep_translator:
                deepTranslatorTfun(lang, slator)
            else: (src: string) => src
        tFuncCache[][(slator.name, lang)] = result

proc initTranslator*(srv: service = default_service, provider: string = "", source: Lang = SLang,
        targets: HashSet[Lang] = TLangs): Translator =
    var py = ensurePy(srv)
    new(result)
    initLock(result.lock)
    case srv:
        of deep_translator:
            result.py = py
            result.apis = toHashSet(["GoogleTranslator", "LingueeTranslator", "MyMemoryTranslator"]) # "single_detection", "batch_detection"
            result.name = srv
            let prov = if provider == "": "GoogleTranslator" else: provider
            assert prov in result.apis
            let
                provFn = result.py.getattr(prov)
                src = source.code
                cls = provFn()
                proxies = if USE_PROXIES:
                              {"https": PROXY_EP, "http": PROXY_EP}.to_table
                          else:
                              {"https": "", "http": ""}.to_table
            for l in targets:
                for suplang in cls.languages.values():
                    let sl = suplang.to(string)
                    if l.code in sl:
                        result.tr[(src, sl)] = provFn(source = src, target = sl, proxies = proxies)
    result
