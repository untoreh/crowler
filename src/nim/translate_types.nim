import
  nimpy,
  tables,
  sets,
  nre,
  xmltree,
  sugar,
  strformat,
  locks,
  karax/vdom,
  macros,
  chronos
export sets

static:
  echo "loading translate types..."
type
  service* = enum
    base_translator = "translator"
    deep_translator = "deep_translator"
    native = "native"
  FcKind* = enum xml, dom
  Lang* = tuple
    name: string
    code: string
  langPair* = tuple[src: string, trg: string]
  TFunc* = proc(src: string, lang: langPair): Future[
      string] {.gcsafe.} ## interface for translation function
  ServiceTable* = Table[langPair, PyObject] ## Maps the api of the wrapped service
  TranslatorObj* = object  ## An instance of a translation service
    pymod*: PyObject       # module
    pycls*: PyObject       # instance of class inside module
    pytranslate*: PyObject # the function that should implement TFunc
    tr*: ServiceTable
    apis*: HashSet[string]
    provider*: string      # must belong in `apis`
    name*: service
    lock*: Lock            # NOTE: Lock is currently unused
  Translator* = ref TranslatorObj
  Queue* = object of RootObj ## An instance of a translation run
    pair*: langPair
    bufsize*: int
    glues*: seq[(string, Regex)]
    sz*: int
  QueueXml* = object of Queue
    bucket*: seq[XmlNode]
  QueueDom* = object of Queue
    bucket*: seq[VNode]
  FileContextBase = object of RootObj
    file_path*: string
    url_path*: string
    pair*: langPair
    t_path*: string
  FileContext* = object of FileContextBase
    case kind: FcKind
    of xml: xhtml*: XmlNode
    of dom: vhtml*: vdom.VNode
  TranslateXmlProc* =
    proc(fc: FileContext, hostname: string, finish: bool): (Queue,
            XmlNode) {.gcsafe.} ## the proc that is called for each `langPair`
  TranslateVNodeProc* =
    proc(fc: FileContext, hostname: string, finish: bool): (Queue,
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

proc initFileContext*(data: XmlNode | VNode; file_path, url_path, pair,
    t_path: auto): ptr FileContext =
  result = create(FileContext)
  if not result.isnil:
    result[] = FileContext(kind: (if data is XmlNode: xml else: dom))
    result.html = data
    result.file_path = file_path
    result.url_path = url_path
    result.pair = pair
    result.t_path = t_path
  else:
    assert false, "Failed to create file context."

const
  default_service* = base_translator
  skip_nodes* = static(["code", "style", "script", "address", "applet", "audio", "canvas",
          "embed", "time", "video", "svg"])
  skip_vnodes* = static([VNodeKind.code, script, VNodeKind.address, audio,
      canvas, embed, time, video, svg])
  skip_class* = ["menu-lang-btn", "material-icons", "rss", "sitemap"].static

pygil.globalAcquire()
let
  pybi = pyBuiltinsModule()
  pytypes = pyImport("types")
pygil.release()

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

proc toTLangs(langs: openArray[(string, string)]): HashSet[Lang] =
  for (name, code) in langs:
    result.incl(initLang(name, code))

proc toLangTable(langs: HashSet[Lang]): Table[string, string] =
  result = initTable[string, string]()
  for (name, code) in langs:
    result[code] = name

const
  SLang* = initLang("English", "en")
  TLangs* = toTLangs [ ## TLangs are all the target languages, the Source language is not included
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
  TLangsTable* = TLangs.toLangTable()
  TLangsCodes* = static(collect(for (name, code) in TLangs: code))
  RTL_LANGS* = ["yi", "he", "ar", "fa", "ur", "az", "dv", ].toHashSet

proc initLang*(code: string): Lang =
  result.code = code
  result.name = TLangsTable[code]

proc srcLangName*(lang: langPair): string = TLangsTable[lang.src]

var glues {.threadvar.}: seq[(string, Regex)]
var gluePadding*: int

let defaultGlues = [
    (" \n[[...]]\n ", re"\s?\n?\[\[?\.\.\.\]\]?\n?"),
    (" <<...>> ", re"\s?<\s?<\s?\.\s?\.\s?\.\s?>\s?>\s?"),
    (" %¶%¶% ", re"\%\s\¶\s?\%\s?\¶\s?\%\s?"),
    (" #|#|# ", re"\s?#\s?\|\s?#\s?\|\s?#\s?")
    ]

var glueTracker*: array[4, int]

proc initGlues*() {.gcsafe.} =
  {.cast(gcsafe).}:
    glues.add defaultGlues
  gluePadding = max:
    collect(for (sep, _) in glues: sep.len)
  gluePadding *= 2

proc initQueue*[T](pair: langPair): T =
  result.glues = glues
  result.bufsize = 5000
  result.pair = pair

import hashes
var queueXmlCache* {.threadvar.}: Table[Hash, QueueXml]
var queueDomCache* {.threadvar.}: Table[Hash, QueueDom]
proc initQueueCache*() =
  queueXmlCache = initTable[Hash, QueueXml]()
  queueDomCache = initTable[Hash, QueueDom]()

macro getCachedQueue(k: Hash, kind: static[int]): untyped =
  case kind:
    of 0:
      quote do:
        queueXmlCache[`k`]
    else:
      quote do:
        queueDomCache[`k`]

proc setCachedQueue(k: Hash, v: QueueXml) = queueXmlCache[k] = v
proc setCachedQueue(k: Hash, v: QueueDom) = queueDomCache[k] = v

macro getQueue*(kind: static[FcKind], pair: langPair): untyped =
  let tp = case kind:
    of xml: QueueXml
    else: QueueDom
  quote do:
    let k = hash((`kind`, `pair`))
    var q: `tp`
    try:
      q = getCachedQueue(k, static(`kind`))
    except KeyError:
      q = initQueue[`tp`](`pair`)
      setCachedQueue(k, q)
    q.bucket.setLen 0
    q.sz = 0
    q
