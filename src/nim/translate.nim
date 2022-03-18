import nimpy
import osproc
import strutils
import strformat
import os
import tables
import sugar
import sets
import sequtils

import quirks
import translate_types
import translate_db

let pybi = pyBuiltinsModule()
let pytypes = pyImport("types")


proc `$`(t: Translator): string =
    let langs = collect(for k in keys(t.tr): k)
    fmt"Translator: {t.name}, to langs ({len(langs)}): {langs}"

proc initLang(name: string, code: string): Lang =
    result.name = name
    result.code = code

proc to_tlangs(langs: openArray[(string, string)]): HashSet[Lang] =
    for (name, code) in langs:
        result.incl(initLang(name, code))

const SLang = initLang("English", "en")
const TLangs = to_tlangs [
    ("German", "de"),
    ("Italian", "it"),
    ("Mandarin Chinese", "zh"),
    ("Spanish", "es"),
    ("Hindi", "hi"),
    ("Arabic", "ar"),
    ("Portuguese", "pt"),
    ("Bengali", "bn"),
    ("Russian", "ru"),
    ("Japanese", "ja"),
    ("Punjabi", "pa"),
    ("Javanese", "jw"),
    ("Vietnamese", "vi"),
    ("French", "fr"),
    ("Urdu", "ur"),
    ("Turkish", "tr"),
    ("Polish", "pl"),
    ("Ukranian", "uk"),
    ("Dutch", "nl"),
    ("Greek", "el"),
    ("Swedish", "sv"),
    ("Zulu", "zu"),
    ("Romanian", "ro"),
    ("Malay", "ms"),
    ("Korean", "ko"),
    ("Thai", "th"),
    ("Filipino", "tl")
    ]

const skip_class = to_hashset []
let transforms = Table[VNodeKind, proc(VNode, string, string, langPair)]
const excluded_dirs = to_hashset []
const included_dirs = to_hashset []

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

proc initTranslator(srv: service = default_service, provider: string = "", source: Lang = SLang,
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
            let provFn = py.getattr(prov)
            let src = source.code
            let cls = provFn()
            for l in targets:
                for suplang in cls.languages.values():
                    let sl = suplang.to(string)
                    if l.code in sl:
                        result.tr[(src, sl)] = provFn(source = src, target = sl)
    result

when isMainModule:
    echo initTranslator()
    # echo r
