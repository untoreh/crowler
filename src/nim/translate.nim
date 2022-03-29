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
       weave/runtime,
       locks

# from karax/vdom import nil
import karax/vdom

import cfg,
       utils,
       translate_types,
       translate_db,
       translate_srv,
       translate_tr,
       translate_tforms

export sugar, translate_types, translate_srv, sets, nre

const excluded_dirs = to_hashset[string](collect(for lang in TLangs: lang.code))
const included_dirs = to_hashset[string]([])

let htmlcache = newLRUCache[string, XmlNode](32)

proc link_src_to_dir(dir: string) =
    let link_path = dir / SLang.code
    if fileExists(link_path) or symlinkExists(link_path):
        warn "Removing file {link_path}"
        removeFile(link_path)
    # NOTE: If the link_path is a directory it will fail
    createSymlink("./", link_path)
    debug "Created symlink from {dir} to {link_path}"

proc isTranslatable(t: string): bool = not (punct_rgx[] in t)
proc isTranslatable(el: XmlNode | vdom.VNode): bool = isTranslatable(el.text)
proc isTranslatable(el: XmlNode, attr: string): bool = isTranslatable(el.attrs[attr])
proc isTranslatable(el: vdom.VNode, attr: string): bool = isTranslatable(vdom.getAttr(el, attr))

let dotsRgx = re"\.?\.?"
proc rewriteUrl(el, rewrite_path, hostname: auto) =
    var uriVar: URI
    parseURI(el.attrs["href"], uriVar)
    # remove initial dots from links
    uriVar.path = uriVar.path.replace(dotRgx, "")
    if uriVar.hostname == "" or uriVar.hostname == hostname and
        uriVar.hostname.startsWith("/"):
        uriVar.path = join(rewrite_path, uriVar.path)
    el.attrs["href"] = $uriVar

template translateEnv(kind: static[FcKind] = xml): untyped {.dirty.} =
    debug "html: initializing vars "
    let
        file_path = fc.file_path
        url_path = fc.url_path
        pair = fc.pair
        tformsTags = collect(for k in getTForms(kind).keys: k).toHashSet()
        rewrite_path = "/" / pair.trg
        srv = fc.slator.name
    var
        otree: XmlNode | vdom.VNode = deepcopy(fc.getHtml(kind))
        q = getTfun(fc.pair, fc.slator).getQueue(kind, fc.pair, fc.slator)
    debug "html: setting root node attributes"

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
    for el in preorder(otree):
        # skip empty nodes
        case el.kind:
            of xnText, xnVerbatimText:
                if el.text.isEmptyOrWhitespace:
                    continue
                if isTranslatable(el):
                    translate(q, el, srv)
            else:
                let t = el.tag
                if t in tformsTags:
                    transforms[][t](el, file_path, url_path, pair)
                if t == "a":
                    if el.attrs.haskey("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif ((el.attrs.haskey "alt") and el.isTranslatable("alt")) or
                     ((el.attrs.haskey "title") and el.isTranslatable("title")):
                    translate(q, el, srv)
    debug "html: finishing translations"
    translate(q, srv, finish = finish)
    (q, otree)
    # return otree
    # raise newException(ValueError, "That's all, folks.")

proc splitUrlPath*(rx, file: auto): auto =
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
                    if el.hasattr("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif ((el.attrs.haskey "alt") and el.isTranslatable("alt")) or
                     ((el.attrs.haskey "title") and el.isTranslatable("title")):
                    translate(q, el, srv)
    (q, otree)

template tryTranslateFunc(kind: FcKind, code: untyped) =
    var q: Queue
    case kind:
        of xml:
            var ot: XmlNode
            (q, ot) = translateHtml(code)
        else:
            var ot: vdom.VNode
            (q, ot) = translateDom(code)

proc tryTranslate(fc: ptr FileContext, kind: FcKind): bool =
    var tries = 0
    while tries < cfg.MAX_TRANSLATION_TRIES:
        try:
            debug "trytrans: scheduling translation"
            tryTranslateFunc(kind, fc)
            debug "trytrans: returning from translations"
            # debug "writing to path {ctx.t_path}"
            # toggle(dowrite):
            # writeFile(fc.t_path, fmt"<!doctype html>\n{ot}")
            return true
        except Exception as e:
            tries += 1
            debug "trytrans: Caught an exception, ({tries}, {e.msg})"
            if tries >= cfg.MAX_TRANSLATION_TRIES:
                warn "Couldn't translate file {fc[].file_path}, exceeded trials"
                return false
    return false


proc translateFile(file, rx, langpairs, slator: auto, target_path = "") =
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
        var fc = initFileContext(html, file_path, url_path, pair, slator, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc, xml)

    syncRoot(Weave)
    saveToDB(force = true)


proc translateTree*(tree: vdom.VNode, file, rx, langpairs, slator: auto, targetPath = "") =
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
        var fc = initFileContext(tree, file_path, url_path, pair, slator, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc, dom)

    syncRoot(Weave)
    saveToDB(force = true)



proc fileWise(path, exclusions, rx_file, langpairs, slator: auto, target_path = "") =
    for file in filterFiles(path, excl_dirs = exclusions, top_dirs = included_dirs):
        debug "file: translating {file}"
        translateFile(file, rx_file, langpairs, slator, target_path = target_path)
        info "file: translation successful for path: {file}"

proc initThread() =
    initPunctRgx()
    initTrans()
    initTFuncCache()

proc exitThread() =
    saveToDB(force = true)

template withWeave*(code: untyped): untyped =
    initThread()
    init(Weave, initThread)
    code
    exitThread()
    exit(Weave, exitThread)

template setupTranslation*(service_kind = deep_translator) {.dirty.} =
    let
        dir = normalizedPath(path)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
        slator = initTranslator(`service_kind`, source = SLang)
        rx_file = re fmt"(.*{dir}/)(.*$)"

proc translateDir(path: string, service_kind = deep_translator, tries = 1, target_path = "") =
    assert path.dirExists
    withWeave:
        setupTranslation(service_kind)
        debug "rgx: Regexp is '(.*{dir}/)(.*$)'."
        link_src_to_dir(dir)
        fileWise(path, excluded_dirs, rx_file, langpairs, slator, target_path = target_path)

when isMainModule:
    import timeit
    let
        dir = normalizePath(SITE_PATH)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
        slator = initTranslator(default_service, source = SLang)
        rx_file = re fmt"(.*{dir}/)(.*$)"
    let
        file = "/home/fra/dev/wsl/site/vps/0/rpresidentialpoll-1844-free-soil-party-convention-vp-balloting.html"
        html = fetchHtml(file)
        (filepath, urlpath) = splitUrlPath(rx_file, file)
        pair = (src: "en", trg: "it")
        t_path = file_path / pair.trg / url_path

    # translateDir(SITE_PATH, target_path = "/tmp/out")
    #
    withWeave:
    # initThread()
        translateFile(file, rx_file, langpairs, slator, target_path = "/tmp/out")
    # withWeave:
    #     echo timeGo do:
    #         discard translateHtml(html, file_path, url_path, pair, slator)
