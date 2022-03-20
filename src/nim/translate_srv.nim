import nimpy,
       os,
       osproc,
       sets,
       sugar,
       strutils,
       strformat,
       tables

# import utils
# import cfg
import translate_types
import quirks
# import translate_db

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

proc getTfun*(lang: langPair, slator: Translator): TFunc =
    case slator.name:
        of deep_translator:
            (src: string) => slator.tr[lang](src).to(string)

proc initTranslator*(srv: service = default_service, provider: string = "", source: Lang = SLang,
        targets: HashSet[Lang] = TLangs): Translator =
    let py = ensurePy(srv)
    new(result)
    case srv:
        of deep_translator:
            result.py = py
            result.apis = toHashSet(["GoogleTranslator", "LingueeTranslator",
                    "MyMemoryTranslator"]) # "single_detection", "batch_detection"
            result.name = srv
            let prov = if provider == "": "GoogleTranslator" else: provider
            assert prov in result.apis
            let
                provFn = py.getattr(prov)
                src = source.code
                cls = provFn()
            for l in targets:
                for suplang in cls.languages.values():
                    let sl = suplang.to(string)
                    if l.code in sl:
                        result.tr[(src, sl)] = provFn(source = src, target = sl)
    result
