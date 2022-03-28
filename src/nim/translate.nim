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
       locks,
       std/deques

import cfg,
       utils,
       translate_types,
       translate_db,
       translate_srv,
       translate_tr,
       translate_tforms


const excluded_dirs = to_hashset[string](collect(for lang in TLangs: lang.code))
const included_dirs = to_hashset[string]([])

let htmlcache = newLRUCache[string, XmlNode](1024)

proc link_src_to_dir(dir: string) =
    let link_path = dir / SLang.code
    if fileExists(link_path) or symlinkExists(link_path):
        warn "Removing file {link_path}"
        removeFile(link_path)
    # NOTE: If the link_path is a directory it will fail
    createSymlink("./", link_path)
    debug "Created symlink from {dir} to {link_path}"



proc isTranslatable(t: string): bool = not (punct_rgx[] in t)
proc isTranslatable(el: XmlNode): bool = isTranslatable(el.text)
proc isTranslatable(el: XmlNode, attr: string): bool = isTranslatable(el.attrs[attr])

proc rewriteUrl(el, rewrite_path, hostname: auto) =
    var uriVar: URI
    parseURI(el.attrs["href"], uriVar)
    # remove initial dots from links
    uriVar.path = uriVar.path.replace(re"\.?\.?", "")
    if uriVar.hostname == "" or uriVar.hostname == hostname and
        uriVar.hostname.startsWith("/"):
        uriVar.path = join(rewrite_path, uriVar.path)
    el.attrs["href"] = $uriVar

proc translateHtml(tree, file_path, url_path, pair, slator: auto,
                   hostname = WEBSITE_DOMAIN, finish = true): auto =
    debug "html: initializing vars "
    let
        tformsTags = collect(for k in transforms.keys: k).toHashSet()
        rewrite_path = "/" / pair.trg
        srv = slator.name
        skip_children = 0
        #
    var
        otree = deepcopy(tree)
        q = getTfun(pair, slator).initQueue(pair, slator)

    debug "html: setting root node attributes"
    # Set the target lang attribute at the top level
    var a: XmlAttributes
    # NOTE: this will crash if the file doesn't have an html tag (as it should)
    a = otree.child("html").attrs
    if a.isnil:
        a = newStringTable()
        otree.child("html").attrs = a
    a["lang"] = pair.trg
    if pair.trg in RTL_LANGS:
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
    return (q, otree)
    # raise newException(ValueError, "That's all, folks.")

proc splitUrlPath(rx, file: auto): auto =
    let m = find(file, rx).get.captures
    (m[0], m[1])

proc fetchHtml(file: string): XmlNode =
    if not (file in htmlcache):
        htmlcache[file] = loadHtml(file)
    return htmlcache[file]

type fileContext = object
    html: XmlNode
    file_path: string
    url_path: string
    pair: langPair
    slator: Translator
    t_path: string

proc initFileContext(html, file_path, url_path, pair, slator, t_path: auto): ptr fileContext =
    result = create(fileContext)
    result.html = html
    result.file_path = file_path
    result.url_path = url_path
    result.pair = pair
    result.slator = slator
    result.t_path = t_path


proc tryTranslate(fc: ptr fileContext): bool =
    var tries = 0
    while tries < cfg.MAX_TRANSLATION_TRIES:
        try:
            let ctx = fc[]
            debug "trytrans: scheduling translation"
            let (_, ot) = translateHtml(ctx.html, ctx.file_path, ctx.url_path, ctx.pair, ctx.slator)
            debug "trytrans: returning from translations"
            # debug "writing to path {ctx.t_path}"
            writeFile(ctx.t_path, $ot)
            return true
        except Exception as e:
            tries += 1
            debug "trytrans: Caught an exception, ({tries})"
            if tries >= cfg.MAX_TRANSLATION_TRIES:
                warn "Couldn't translate file {fc[].file_path}, {e.msg}"
                return false
    return false

proc translateFile(file, rx, langpairs, slator: auto, target_path = "") =
    let
        html = fetchHtml(file)
        (filepath, urlpath) = splitUrlPath(rx, file)
    debug "translating file {file}"
    var jobs: seq[Flowvar[bool]]
    # Hold references of variables created inside the loop until all jobs have finished
    var ctxs: seq[ptr fileContext]

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
        let j = spawn tryTranslate(fc)
        jobs.add j
    syncRoot(Weave)
    saveToDB(force=true)



proc fileWise(path, exclusions, rx_file, langpairs, slator: auto, target_path="") =
    for file in filterFiles(path, excl_dirs = exclusions, top_dirs = included_dirs):
        debug "file: translating {file}"
        translateFile(file, rx_file, langpairs, slator, target_path=target_path)
        info "file: translation successful for path: {file}"

proc initThread() =
    initPunctRgx()
    initTrans()
    initTFuncCache()

proc exitThread() =
    saveToDB(force = true)

template withWeave(code: untyped): untyped =
    initThread()
    init(Weave, initThread)
    code
    exitThread()
    exit(Weave, exitThread)

proc translateDir(path: string, service = deep_translator, tries = 1, target_path="") =
    assert path.dirExists
    withWeave:
        let
            dir = normalizePath(path)
            langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
            slator = initTranslator(service, source = SLang)
            rx_file = re fmt"(.*{dir}/)(.*$)"

        debug "rgx: Regexp is '(.*{dir}/)(.*$)'."
        link_src_to_dir(dir)
        fileWise(path, excluded_dirs, rx_file, langpairs, slator, target_path=target_path)

when isMainModule:
    import timeit
    let
        dir = normalizePath(SITE_PATH)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
        slator = initTranslator(default_service, source = SLang)
        rx_file = re fmt"(.*{dir}/)(.*$)"
    let
        file = "/home/fra/dev/wsl/site/vps/0/rwireguard-free-vps-for-wireguard.html"
        html = fetchHtml(file)
        (filepath, urlpath) = splitUrlPath(rx_file, file)
        pair = (src: "en", trg: "it")
        t_path = file_path / pair.trg / url_path

    translateDir(SITE_PATH, target_path = "/tmp/out")
    #
    # withWeave:
    #     translateFile(file, rx_file, langpairs, slator, target_path = "/tmp/out")
    # withWeave:
    #     echo timeGo do:
    #         discard translateHtml(html, file_path, url_path, pair, slator)
