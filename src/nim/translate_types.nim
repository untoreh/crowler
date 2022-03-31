import nimpy
import tables
import sets
import nre
import xmltree
import sugar
import strformat
import locks
import karax/vdom
import macros

type
    service* = enum
        deep_translator = "deep_translator"
    FcKind* = enum xml, dom
    Lang* = tuple
        name: string
        code: string
    langPair* = tuple[src: string, trg: string]
    ServiceTable* = Table[langPair, PyObject] ## Maps the api of the wrapped service
    Translator* = ref object ## An instance of a translation service
        py*: PyObject
        tr*: ServiceTable
        apis*: HashSet[string]
        name*: service
        lock*: Lock
    Queue* = object of RootObj ## An instance of a translation run
        pair*: langPair
        slator*: Translator
        bufsize*: int
        glues*: seq[(string, Regex)]
        sz*: int
        call*: TFunc
    QueueXml* = object of Queue
        bucket*: seq[XmlNode]
    QueueDom* = object of Queue
        bucket*: seq[VNode]
    TFunc* = proc(src: string): string {.gcsafe.} ## the proc that wraps a translation service call
    FileContextBase = object of RootObj
        file_path*: string
        url_path*: string
        pair*: langPair
        slator*: Translator
        t_path*: string
    FileContext* = object of FileContextBase
        case kind: FcKind
        of xml: xhtml*: XmlNode
        of dom: vhtml*: vdom.VNode
    TranslateXmlProc* = proc(fc: FileContext, hostname: string, finish: bool): (Queue,
            XmlNode) {.gcsafe.} ## the proc that is called for each `langPair`
    TranslateVNodeProc* = proc(fc: FileContext, hostname: string, finish: bool): (Queue,
            VNode) {.gcsafe.} ## the proc that is called for each `langPair`

macro getHtml*(code: untyped, kind: static[FcKind], ): untyped =
    case kind:
        of xml:
            quote do:
                `code`.xhtml
        else:
            quote do:
                `code`.vhtml

proc `html=`*(fc: ptr FileContext, data: XmlNode) = fc.xhtml = data
proc `html=`*(fc: ptr FileContext, data: vdom.VNode) = fc.vhtml = data

proc initFileContext*(data, file_path, url_path, pair, slator, t_path: auto): ptr FileContext =
    result = create(FileContext)

    if data is XmlNode:
        result.kind = xml
    else:
        result.kind = dom
    result.html = data
    result.file_path = file_path
    result.url_path = url_path
    result.pair = pair
    result.slator = slator
    result.t_path = t_path

const
    default_service* = deep_translator
    skip_nodes* = static(["code", "style", "script", "address", "applet", "audio", "canvas",
            "embed", "time", "video", "svg"])
    skip_vnodes* = static([VNodeKind.code, style, script, address, audio, canvas, embed, time, video, svg])
    skip_class* = ["menu-lang-btn", "material-icons"].static

let
    pybi = pyBuiltinsModule()
    pytypes = pyImport("types")

var punct_rgx* {.threadvar.}: Regex

proc initPunctRgx*() =
    if punct_rgx.isnil:
        punct_rgx = re"^([[:punct:]]|\s)+$"

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

var glues {.threadvar.} : seq[(string, Regex)]

proc initGlues*() =
    glues = @[
    (" #|#|# ", re"\s?#\s?\|\s?#\s?\|\s?#\s?"),
    (" <<...>> ", re"\s?<\s?<\s?\.\s?\.\s?\.\s?>\s?>\s?"),
    (" %¶%¶% ", re"\%\s\¶\s?\%\s?\¶\s?\%\s?"),
    (" \n[[...]]\n ", re"\s?\n?\[\[?\.\.\.\]\]?\n?")
    ]

proc initQueue*[T](f: TFunc, pair, slator: auto): T =
    result.glues = glues
    result.bufsize = 5000
    result.call = f
    result.pair = pair
    result.slator = slator

macro getQueue*(f: TFunc, kind: static[FcKind], pair, slator: untyped): untyped =
    let tp = case kind:
        of xml: QueueXml
        else: QueueDom
    quote do:
        initQueue[`tp`](`f`, `pair`, `slator`)

when isMainModule:
    import sugar
    import strtabs
    let t = "a"
    var tb = initTable[string, TransformFunc]()
    let ks = collect(for k in tb.keys: k).toHashSet
    # t["ok"] = (proc (el: XmlNode, file: string, url: string, pair: langPair) = discard nil)
    if t in ks:
        echo typeof(tb[t])
