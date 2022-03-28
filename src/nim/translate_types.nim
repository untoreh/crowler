import nimpy
import tables
import sets
import nre
import xmltree
import sugar
import strformat
import locks

type
    service* = enum
        deep_translator = "deep_translator"
    Lang* = tuple
        name: string
        code: string
    langPair* = tuple[src: string, trg: string]
    tFunc = PyObject
    tTable* = Table[langPair, tFunc]
    Translator* = ref object
        py*: PyObject
        tr*: tTable
        apis*: HashSet[string]
        name*: service
        lock*: Lock
    Queue* = object of RootObj
        pair*: langPair
        slator*: Translator
        bufsize*: int
        glues*: seq[(string, Regex)]
        sz*: int
        bucket*: seq[XmlNode]
        call*: TFunc
    QueueKind = enum
        Glue
    TFunc* = proc(src: string): string {.gcsafe.}
    GlueQueue* = object of Queue



const
    default_service* = deep_translator
    skip_nodes* = static(["code", "style", "script", "address", "applet", "audio", "canvas",
            "embed", "time", "video"])
    skip_class* = ["menu-lang-btn"].static

let
    pybi = pyBuiltinsModule()
    pytypes = pyImport("types")

var punct_rgx* {.threadvar.}: ptr Regex

proc initPunctRgx*() =
    if punct_rgx.isnil:
        punct_rgx = create(Regex)
        punct_rgx[] = re"^([[:punct:]]|\s)+$"

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
        ("Mandarin Chinese", "zh-CN"),
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

proc initQueue*(f: TFunc, pair, slator: auto, kind: QueueKind = Glue): Queue =
    case kind:
        of Glue:
            var q: GlueQueue
            q.glues = @[
                ("#|#|#", re"\s?#\s?\|\s?#\s?\|\s?#\s?"),
                (" \n[[...]]\n ", re"\s?\n?\[\[?\.\.\.\]\]?\n?"),
                (" %¶%¶% ", re"%\s¶\s?%\s?¶\s?%")
                ]
            q.bufsize = 5000
            q.call = f
            q.pair = pair
            q.slator = slator
            return q
        else:
            result

when isMainModule:
    import sugar
    import strtabs
    let t = "a"
    var tb = initTable[string, TransformFunc]()
    let ks = collect(for k in tb.keys: k).toHashSet
    # t["ok"] = (proc (el: XmlNode, file: string, url: string, pair: langPair) = discard nil)
    if t in ks:
        echo typeof(tb[t])
