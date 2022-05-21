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
    quirks,
    pyutils

static: echo "loading translate_srv"

let pyGlo = pyGlobals()
var tFuncCache* {.threadvar.}: ptr Table[(service, langpair), TFunc]

proc initTFuncCache*() =
    if tFuncCache.isnil:
        tFuncCache = createShared(Table[(service, langpair), TFunc])

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
let
    tryWrapper = pyglo["tryWrapper"]
    pySched = relpyImport("scheduler")

discard pySched.initPool()

proc trywrapPyFunc(fn: PyObject, tries = 3, defVal = ""): PyObject =
    debug "trywrap: returning try wrapper {tries}"
    return tryWrapper(fn, tries, defVal)

template pySafeCall(code: untyped): untyped =
    debug "pysafe: acquiring lock"
    try:
        pyLock.acquire()
        debug "pysafe: lock acquired"
        code
    except:
        debug "pysafe: Failed with exception... {getCurrentException()[]}"
    finally:
        debug "pysafe: releasing lock"
        pyLock.release()
    debug "pysafe: lock released"

proc getProxies(srv: service = deep_translator): auto =
    case srv:
        of deep_translator:
            if USE_PROXIES:
                debug "trsrv: enabling proxies with endpoint {PROXY_EP}"
                {"https": PROXY_EP, "http": PROXY_EP}.to_table
            else:
                {"https": "", "http": ""}.to_table


proc initTranslator*(srv: service = default_service, provider: string = "", source: Lang = SLang,
        targets: HashSet[Lang] = TLangs): Translator =
    var py = ensurePy(srv)
    new(result)
    case srv:
        of deep_translator:
            result.py = py
            result.apis = toHashSet(["GoogleTranslator", "LingueeTranslator",
                    "MyMemoryTranslator"]) # "single_detection", "batch_detection"
            result.name = srv
            let prov = if provider == "": "GoogleTranslator" else: provider
            assert prov in result.apis
            result.provider = prov
            let
                provFn = result.py.getattr(prov)
                src = source.code
                cls = provFn()
                proxies = getProxies(srv)
            for l in targets:
                for suplang in cls.languages.values():
                    let sl = suplang.to(string)
                    if l.code in sl:
                        result.tr[(src, sl)] = provFn(source = src, target = sl, proxies = proxies)
    result

let slatorObj = initTranslator()
let slator* = slatorObj.unsafeAddr


proc deepTranslatorFunc(src: string, lang: langPair): string {.gcsafe.} =
    # NOTE: using `slator` inside the closure is fine since it always outlives the closure
    try:
        var
            res {.threadvar.}: PyObject
            rdy {.threadvar.}: bool
            j {.threadvar.}: PyObject
            pyf {.threadvar.}: PyObject
        pySafeCall:
            debug "tfun: applying function with src ({src.len})"
            debug "slator nil?: {slator.tr[lang].isnil}"
            # debug "slator py object: {slator.tr[lang].getattr(\"translate\")}"
            pyf = slator.tr[lang].getattr("translate").trywrapPyFunc
            # debug "tfun: is src valid utf8? {validateUtf8(src)}"
            debug "tfun: scheduling translation, pysched: {pySched.isnil}, pyf: {pyf.isnil}, slator: {slator.tr[lang].isnil}, tr: {slator.tr[lang].getattr(\"translate\").isnil}"
            j = pySched.apply(pyf, src)
            debug "tfun: applied f ({src.len})"
        while true:
            pySafeCall:
                debug "tfun: waiting for translation {rdy}, {lang}, {j.isnil}"
                discard j.wait(cfg.TRANSLATION_TIMEOUT)
                rdy = j.ready().to(bool)
            if rdy:
                debug "tfun: getting translation value job"
                pySafeCall: res = j.get()
                break
        # debug "tfun: marshaling res, isnil? {res.isnil}"
        # debug "tfun: res:{$res}"
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

proc setPairFun*(pair: langPair) =
    case slator.name:
        of deep_translator:
            let provfn = slator.py.getattr(slator[].provider)
            slator.tr[pair] = provfn(source = pair.src, target = pair.trg, proxies = getProxies(deep_translator))

proc getTfun*(lang: langPair): TFunc =
    case slator.name:
        of deep_translator:
            if not (lang in slator[].tr):
                setPairFun(lang)
            deepTranslatorFunc
        else: (src: string, lang: langPair) => src
