import nimpy,
       strutils,
       strformat,
       os,
       tables,
       sugar,
       sets,
       pathnorm,
       htmlparser,
       xmltree,
       options,
       strtabs,
       uri,
       std/wrapnils,
       lrucache,
       locks,
       macros,
       std/sharedtables,
       chronos

# from karax/vdom import nil
import karax/vdom

import cfg,
       types,
       utils,
       translate_types,
       translate_db,
       translate_srv,
       translate_tr,
       translate_tforms,
       html_misc

export translate_types

static: echo "loading translate..."

export sugar, translate_types, translate_srv, sets

const excluded_dirs = to_hashset[string](collect(for lang in TLangs: lang.code))
const included_dirs = to_hashset[string]([])

let htmlcache = newLRUCache[string, XmlNode](32)
var vbtmcache* {.threadvar.}: LruCache[array[5, byte], XmlNode]
var rxcache {.threadvar.}: LruCache[string, Regex]
let trOut* = initLockTable[string, VNode]()
var translateFuts* {.threadvar.}: LruCache[string, (VNode, Future[bool])]

# proc get*[K, V](c: LruCache[K, V], k: K): V = c[k]

proc getDirRx*(dir: string): Regex =
    try:
        rxcache[dir]
    except KeyError:
        rxcache[dir] = re fmt"(.*{dir}/)(.*$)"
        return rxcache[dir]

proc link_src_to_dir(dir: string) =
    let link_path = dir / SLang.code
    if fileExists(link_path) or symlinkExists(link_path):
        warn "Removing file {link_path}"
        removeFile(link_path)
    # NOTE: If the link_path is a directory it will fail
    createSymlink("./", link_path)
    debug "Created symlink from {dir} to {link_path}"

proc isTranslatable*(t: string): bool = not (punct_rgx in t)
proc isTranslatable*(el: XmlNode | vdom.VNode): bool = isTranslatable(el.text)
proc isTranslatable*(el: XmlNode, attr: string): bool = isTranslatable(el.attrs[attr])
proc isTranslatable*(el: vdom.VNode, attr: string): bool = isTranslatable(vdom.getAttr(el, attr))


macro defIfDom*(kind: static[FcKind]): untyped =
    case kind:
        of dom:
            quote do:
                var
                    xq {.inject.} = getQueue(xml, fc.pair)
                    xtformsTags {.inject.} = collect(for k in getTForms(xml).keys: k).toHashSet()
        else:
            quote do:
                discard

template translateEnv*(kind: static[FcKind] = xml) {.dirty.} =
    debug "html: initializing vars "
    let
        file_path = fc.file_path
        url_path = fc.url_path
        pair = fc.pair
        tformsTags = collect(for k in getTForms(kind).keys: k).toHashSet()
        rewrite_path = "/" / pair.trg
        srv = slator.name
    var
        otree = deepcopy(fc.getHtml(kind))
        q = getQueue(kind, fc.pair)

    defIfDom(kind)

    debug "html: setting root node attributes"

template translateNode*(otree: XmlNode, q: QueueXml, tformsTags: auto, fin = false) =
    for el in preorder(otree):
        # skip empty nodes
        case el.kind:
            of xnText, xnVerbatimText:
                if el.text.isEmptyOrWhitespace:
                    continue
                if isTranslatable(el):
                    translate(q.addr, el, srv)
            else:
                let t = el.tag
                if t in tformsTags:
                    getTforms(xml)[t](el, file_path, url_path, pair)
                if t == "a":
                    if el.hasAttr("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif ((el.hasAttr("alt")) and el.isTranslatable("alt")) or
                     ((el.hasAttr("title")) and el.isTranslatable("title")):
                    translate(q.addr, el, srv)
    discard await translate(q.addr, srv, finish = fin)


template translateNode*(node: VNode, q: QueueXml) =
    ## deprecated, see translate_lang `translateVbtm`
    assert node.kind == VNodeKind.verbatim
    let
        s = $node
        tree = vbtmcache.lcheckOrPut(s.key): parseHtml(s)
        otree = deepcopy(tree)
    when declared(finish):
        finish = false # FIXME: This overrides `finish` argument
    else:
        let finish = true
    translateNode(otree, q, xtformsTags, finish)
    type ShString {.shallow.} = string
    node.value = if otree.kind == xnElement and otree.tag == "document":
                    var outStr: ShString
                    for c in otree:
                      outStr.add withClosingHtmlTag(c)
                    outStr
                 else:
                   withClosingHtmlTag(otree)

proc splitUrlPath*(rx: Regex, file: auto): auto =
    # debug "translate: splitting for file {file} with pattern {rx.pattern}"
    let m = find(file, rx).get.captures
    (m[0], m[1])

proc fetchHtml(file: string): XmlNode =
    if not (file in htmlcache):
        htmlcache[file] = loadHtml(file)
    return htmlcache[file]

when defined(weaveRuntime):
  import translate_weave

proc initTranslate*() =
  try:
    initTranslateDB()
    initPunctRgx()
    setNil(vbtmcache):
      newLRUCache[array[5, byte], XmlNode](32)
    initGlues()
    initSlations()
    initTforms()
    when nativeTranslator:
      startTranslate()
    translateFuts = newLruCache[string, (VNode, Future[bool])](10000)
  except:
    logexc()
    qdebug "Failed to init translate."

proc exitThread() =
    saveToDB(force = true)

template setupTranslation*(service_kind = deep_translator, fpath = "") {.dirty.} =
    let
        dir = normalizedPath(if fpath == "": fpath else: path)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code)).static
        rx_file = getDirRx(dir)
