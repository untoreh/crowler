import nimpy,
       strutils,
       strformat,
       os,
       tables,
       sugar,
       sets,
       pathnorm,
       nre,
       htmlparser,
       xmltree,
       options,
       strtabs,
       uri,
       std/wrapnils,
       lrucache,
       weave,
       weave/[runtime, contexts],
       locks,
       macros,
       std/sharedtables

# from karax/vdom import nil
import karax/vdom

import cfg,
       types,
       utils,
       translate_types,
       translate_db,
       translate_srv,
       translate_tr,
       translate_tforms

export translate_types

static: echo "loading translate..."

export sugar, translate_types, translate_srv, sets, nre

const excluded_dirs = to_hashset[string](collect(for lang in TLangs: lang.code))
const included_dirs = to_hashset[string]([])

let htmlcache = newLRUCache[string, XmlNode](32)
var vbtmcache {.threadvar.}: LruCache[array[5, byte], XmlNode]
var rxcache {.threadvar.}: LruCache[string, Regex]
let trOut* = initLockTable[string, VNode]()

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

proc isTranslatable(t: string): bool = not (punct_rgx in t)
proc isTranslatable(el: XmlNode | vdom.VNode): bool = isTranslatable(el.text)
proc isTranslatable(el: XmlNode, attr: string): bool = isTranslatable(el.attrs[attr])
proc isTranslatable(el: vdom.VNode, attr: string): bool = isTranslatable(vdom.getAttr(el, attr))

var dotsRgx {.threadvar.}: Regex
var uriVar {.threadVar.}: URI

proc rewriteUrl(el, rewrite_path, hostname: auto) =
    parseURI(el.getAttr("href"), uriVar)
    # remove initial dots from links
    uriVar.path = uriVar.path.replace(dotsRgx, "")
    if uriVar.hostname == "" or (uriVar.hostname == hostname and
        uriVar.hostname.startsWith("/")):
        uriVar.path = joinpath(rewrite_path, uriVar.path)
    el.setAttr("href", $uriVar)
    # debug "old: {prev} new: {$uriVar}, {rewrite_path}"

macro defIfDom(kind: static[FcKind]): untyped =
    case kind:
        of dom:
            quote do:
                var
                    xq {.inject.} = getTfun(fc.pair).getQueue(xml, fc.pair)
                    xtformsTags {.inject.} = collect(for k in getTForms(xml).keys: k).toHashSet()
        else:
            quote do:
                discard

template translateEnv(kind: static[FcKind] = xml): untyped {.dirty.} =
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
        q = getTfun(fc.pair).getQueue(kind, fc.pair)

    defIfDom(kind)

    debug "html: setting root node attributes"

template translateNode(otree: XmlNode, q: QueueXml, tformsTags: auto) =
    for el in preorder(otree):
        # skip empty nodes
        case el.kind:
            of xnText, xnVerbatimText:
                discard
                if el.text.isEmptyOrWhitespace:
                    continue
                if isTranslatable(el):
                    translate(q, el, srv)
            else:
                let t = el.tag
                if t in tformsTags:
                    getTforms(xml)[][t](el, file_path, url_path, pair)
                if t == "a":
                    if el.hasAttr("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif ((el.hasAttr("alt")) and el.isTranslatable("alt")) or
                     ((el.hasAttr("title")) and el.isTranslatable("title")):
                    translate(q, el, srv)
    translate(q, srv, finish = finish)

template translateNode(node: VNode, q: QueueXml) =
    assert node.kind == VNodeKind.verbatim
    let
        s = node.text
        tree = try:
                   vbtmcache[s.key]
               except:
                   vbtmcache[s.key] = parseHtml(s)
                   vbtmcache[s.key]
        otree = deepcopy(tree)
    translateNode(otree, q, xtformsTags)
    node.text = $otree

proc translateHtml(fc: ptr FileContext, hostname = WEBSITE_DOMAIN, finish = true): auto =
    translateEnv()

    # Set the target lang attribute at the top level
    var a: XmlAttributes
    # NOTE: this will crash if the file doesn't have an html tag (as it should)
    a = otree.child("html").attrs
    if a.isnil:
        a = newStringTable()
        otree.child("html").attrs = a
    a["lang"] = fc.pair.trg
    if fc.pair.trg in RTL_LANGS:
        a["dir"] = "rtl"

    debug "html: recursing tree..."
    translateNode(otree, q, tformsTags)
    debug "html: finished translations"
    (q, otree)
    # raise newException(ValueError, "That's all, folks.")

proc splitUrlPath*(rx: Regex, file: auto): auto =
    # debug "translate: splitting for file {file} with pattern {rx.pattern}"
    let m = find(file, rx).get.captures
    (m[0], m[1])

proc fetchHtml(file: string): XmlNode =
    if not (file in htmlcache):
        htmlcache[file] = loadHtml(file)
    return htmlcache[file]

proc translateDom(fc: ptr FileContext, hostname = WEBSITE_DOMAIN, finish = true): auto =
    translateEnv(dom)
    for node in otree.preorder():
        case node.kind:
            of vdom.VNodeKind.html:
                node.setAttr("lang", pair.trg)
                if pair.trg in RTL_LANGS:
                    node.setAttr("dir", "rtl")
                break
            else: continue
    for el in otree.preorder():
        case el.kind:
            of vdom.VNodeKind.text:
                if el.text.isEmptyOrWhitespace:
                    continue
                if isTranslatable(el):
                    translate(q, el, srv)
            else:
                let t = el.kind
                if t in tformsTags:
                    getTForms(dom)[][t](el, file_path, url_path, pair)
                if t == VNodeKind.a:
                    if el.hasAttr("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif t == VNodeKind.verbatim:
                    debug "dom: translating verbatim"
                    translateNode(el, xq)
                elif ((el.hasAttr("alt")) and el.isTranslatable("alt")) or
                        ((el.hasAttr("title")) and el.isTranslatable("title")):
                    translate(q, el, srv)
    debug "dom: finishing translations"
    translate(q, srv, finish = finish)
    (q, otree)

template tryTranslateFunc(kind: FcKind, args: untyped, post: untyped) {.dirty.} =
    var q: Queue
    case kind:
        of xml:
            var ot: XmlNode
            (q, ot) = translateHtml(args)
            post
        else:
            var ot: vdom.VNode
            trOut.clear()
            (q, ot) = translateDom(args)
            # FIXME
            trOut[fc.pair.trg] = ot
            post
    debug "trytrans: returning from translations"

proc tryTranslate(fc: ptr FileContext, kind: FcKind): bool =
    var tries = 0
    while tries < cfg.MAX_TRANSLATION_TRIES:
        try:
            debug "trytrans: scheduling translation"
            tryTranslateFunc(kind, fc):
                toggle(TRANSLATION_TO_FILE):
                    debug "writing to path {fc.t_path}"
                    writeFile(fc.t_path, fmt"<!doctype html>{'\n'}{ot}")
            return true
        except Exception as e:
            tries += 1
            debug "trytrans: Caught an exception, ({tries}, {e.msg})"
            if tries >= cfg.MAX_TRANSLATION_TRIES:
                warn "Couldn't translate file {fc[].file_path}, exceeded trials"
                return false
    return false

proc translateFile(file, rx, langpairs: auto, target_path = "") =
    let
        html = fetchHtml(file)
        (filepath, urlpath) = splitUrlPath(rx, file)
    debug "translating file {file}"
    var jobs: seq[Flowvar[bool]]
    # Hold references of variables created inside the loop until all jobs have finished
    var ctxs: seq[ptr FileContext]

    for pair in langpairs:
        let
            t_path = if target_path == "":
                        file_path / pair.trg / url_path
                    else:
                        target_path / pair.trg / url_path
            d_path = parentDir(t_path)
        if not dirExists(d_path):
            createDir(d_path)
        var fc = initFileContext(html, file_path, url_path, pair, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc, xml)

    syncRoot(Weave)
    saveToDB(force = true)


proc translateTree*(tree: vdom.VNode, file, rx, langpairs: auto, targetPath = "",
        ar = emptyArt) {.gcsafe.} =
    ## Translate a `VNode` tree to multiple languages

    let (filepath, urlpath) = splitUrlPath(rx, file)
    var jobs: seq[Flowvar[bool]]
    # Hold references of variables created inside the loop until all jobs have finished
    var ctxs: seq[ptr FileContext]

    let getTargetPath = if targetPath == "": (pair: langPair) => file_path / pair.trg / url_path
                        else: (pair: langPair) => target_path / pair.trg / url_path

    for pair in langpairs:
        let t_path = getTargetPath(pair)
        let d_path = parentDir(t_path)
        if not dirExists(d_path):
            createDir(d_path)
        var fc = initFileContext(tree, file_path, url_path, pair, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc, dom)

    syncRoot(Weave)
    saveToDB(force = true)

proc translateLang(tree: vdom.VNode, file, rx: auto, lang: langPair, targetPath = "",
        ar = emptyArt): VNode {.gcsafe.} =
    let
        (filepath, urlpath) = splitUrlPath(rx, file)
        t_path = if targetPath == "": file_path / lang.trg / url_path
    var fc = initFileContext(tree, file_path, url_path, lang, t_path)
    translateDom(fc)[1]

proc fileWise(path, exclusions, rx_file, langpairs: auto, target_path = "") =
    for file in filterFiles(path, excl_dirs = exclusions, top_dirs = included_dirs):
        debug "file: translating {file}"
        translateFile(file, rx_file, langpairs, target_path = target_path)
        info "file: translation successful for path: {file}"

proc initThread*() =
    initPunctRgx()
    initTrans()
    if vbtmcache.isnil:
        vbtmcache = newLRUCache[array[5, byte], XmlNode](32)
    initSentsRgx()
    initGlues()
    initQueueCache()
    dotsRgx = re"^\.?\.?"

proc exitThread() =
    saveToDB(force = true)


template withWeave*(doexit = false, args: untyped) =
    # os.putenv("WEAVE_NUM_THREADS", "2")
    if isWeaveOff():
        init(Weave, initThread)
        initThread()
    args
    if doexit:
        exit(Weave, exitThread)
        exitThread()

template setupTranslation*(service_kind = deep_translator, fpath = "") {.dirty.} =
    let
        dir = normalizedPath(if fpath == "": fpath else: path)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code)).static
        rx_file = getDirRx(dir)

proc translateDir(path: string, service_kind = deep_translator, tries = 1, target_path = "") =
    assert path.dirExists
    withWeave(doexit = true):
        setupTranslation(service_kind)
        debug "rgx: Regexp is '(.*{dir}/)(.*$)'."
        link_src_to_dir(dir)
        fileWise(path, excluded_dirs, rx_file, langpairs, target_path = target_path)

when isMainModule:
    import timeit
    let
        dir = normalizePath(SITE_PATH)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
        rx_file = re fmt"(.*{dir}/)(.*$)"
    let
        file = "/home/fra/dev/wsl/site/vps/1/cheap-dedicated-server-hosting-price-best-dedicated-hosting-plans.html"
        html = fetchHtml(file)
        (filepath, urlpath) = splitUrlPath(rx_file, file)
        pair = (src: "en", trg: "it")
        t_path = file_path / pair.trg / url_path

    # translateDir(SITE_PATH, target_path = "/tmp/out")
    #
    withWeave(true):
        translateFile(file, rx_file, langpairs, target_path = "/tmp/out")

    # withWeave:
    #     echo timeGo do:
    #         discard translateHtml(html, file_path, url_path, pair, slator)
