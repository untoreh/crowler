import nimpy
import tables
import sets
import nre
import xmltree
import sugar
import strformat

type
    service* = enum
        deep_translator = "deep_translator"
    Lang* = tuple
        name: string
        code: string
    langPair* = tuple[src: string, trg: string]
    tFunc = PyObject
    tTable = Table[langPair, tFunc]
    Translator* = ref object
        py*: PyObject
        tr*: tTable
        apis*: HashSet[string]
        name*: service
    TransformFunc* = proc(el: XmlNode, file: string, url: string, pair: langPair)
    Queue* = object of RootObj
    QueueKind = enum
        Glue
    TFunc* = proc(src: string): string
    GlueQueue* = object of Queue
        sz*: int
        bucket*: seq[string]
        glue*: string
        splitGlue*: Regex
        bufsize*: int
        translate*: TFunc
        pair*: langPair
        slator*: Translator



const
    default_service* = deep_translator
    skip_nodes* = static(["code", "style", "script", "address", "applet", "audio", "canvas",
            "embed", "time", "video"])
    skip_class* = ["menu-lang-btn"].static

let
    punct_rgx* = re"^([[:punct:]]|\s)+$"
    pybi = pyBuiltinsModule()
    pytypes = pyImport("types")


proc `$`*(t: Translator): string =
    let langs = collect(for k in keys(t.tr): k)
    fmt"Translator: {t.name}, to langs ({len(langs)}): {langs}"

proc initLang*(name: string, code: string): Lang =
    result.name = name
    result.code = code

proc to_tlangs(langs: openArray[(string, string)]): HashSet[Lang] =
    for (name, code) in langs:
        result.incl(initLang(name, code))

const
    SLang* = initLang("English", "en")
    TLangs* = to_tlangs [
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
    RTL_LANGS* = ["yi", "he", "ar", "fa", "ur", "az", "dv", ].toHashSet

proc initQueue*(f: TFunc, pair, slator: auto, kind: QueueKind = Glue): auto =
    case kind:
        of Glue:
            var q: GlueQueue
            q.glue = " \n[[...]]\n "
            q.splitGlue = re"\s?\n?\[\[?\.\.\.\]\]?\n?"
            q.bufsize = 1600
            q.translate = f
            q.pair = pair
            q.slator = slator
            return q



when isMainModule:
    echo "ok"
