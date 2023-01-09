proc translateDom(fc: ptr FileContext, hostname = config.websiteDomain, finish = true): auto =
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
                    translate(q.addr, el, srv)
            else:
                let t = el.kind
                if t in tformsTags:
                    getTForms(dom)[t](el, file_path, url_path, pair)
                if t == VNodeKind.a:
                    if el.hasAttr("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif t == VNodeKind.verbatim:
                    debug "dom: translating verbatim"
                    translateNode(el, xq)
                elif ((el.hasAttr("alt")) and el.isTranslatable("alt")) or
                        ((el.hasAttr("title")) and el.isTranslatable("title")):
                    translate(q.addr, el, srv)
    debug "dom: finishing translations"
    discard waitFor translate(q.addr, srv, finish = finish)
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
    var ctxs: seq[FileContext]
    defer:
        for fc in ctxs:
        free(fc)

    for pair in langpairs:
        let
            t_path = if target_path == "":
                        file_path / pair.trg / url_path
                    else:
                        target_path / pair.trg / url_path
            d_path = parentDir(t_path)
        if not dirExists(d_path):
            createDir(d_path)
        let fc = init(FileContext, html, file_path, url_path, pair, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc.addr, xml)

    syncRoot(Weave)
    saveToDB(force = true)


proc translateTree*(tree: vdom.VNode, file, rx, langpairs: auto, targetPath = "",
        ar = emptyArt) {.gcsafe.} =
    ## Translate a `VNode` tree to multiple languages

    let (filepath, urlpath) = splitUrlPath(rx, file)
    var jobs: seq[Flowvar[bool]]
    # Hold references of variables created inside the loop until all jobs have finished
    var ctxs: seq[FileContext]
    defer:
        for fc in ctxs: free(fc)

    let getTargetPath = if targetPath == "": (pair: langPair) => file_path / pair.trg / url_path
                        else: (pair: langPair) => target_path / pair.trg / url_path

    for pair in langpairs:
        let t_path = getTargetPath(pair)
        let d_path = parentDir(t_path)
        if not dirExists(d_path):
            createDir(d_path)
        let fc = init(tree, file_path, url_path, pair, t_path)
        ctxs.add(fc)
        let j = spawn tryTranslate(fc.addr, dom)

    syncRoot(Weave)
    saveToDB(force = true)


proc fileWise(path, exclusions, rx_file, langpairs: auto, target_path = "") =
    for file in filterFiles(path, excl_dirs = exclusions, top_dirs = included_dirs):
        debug "file: translating {file}"
        translateFile(file, rx_file, langpairs, target_path = target_path)
        info "file: translation successful for path: {file}"

proc translateDir(path: string, service_kind = deep_translator, tries = 1, target_path = "") =
    assert path.dirExists
    withWeave(doexit = true):
        setupTranslation(service_kind)
        debug "rgx: Regexp is '(.*{dir}/)(.*$)'."
        link_src_to_dir(dir)
        fileWise(path, excluded_dirs, rx_file, langpairs, target_path = target_path)

proc translateHtml(fc: ptr FileContext, hostname = config.websiteDomain, finish = true): auto =
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
