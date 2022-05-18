import
    os,
    karax/vdom,
    strutils,
    xmltree

import
    cfg,
    utils,
    types,
    translate_types,
    translate_tforms,
    translate_tr,
    translate_srv,
    translate

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

proc translateLang*(tree: vdom.VNode, file, rx: auto, lang: langPair, targetPath = "",
        ar = emptyArt): VNode {.gcsafe.} =
    let
        (filedir, relpath) = splitUrlPath(rx, file)
        t_path = if targetPath == "": filedir / lang.trg / (if relpath == "": "index.html" else: relpath)
                 else: targetPath
    var fc = initFileContext(tree, filedir, relpath, lang, t_path)
    translateDom(fc)[1]

proc translateLang*(fc: ptr FileContext, ar = emptyArt): VNode {.gcsafe.} =
    translateDom(fc)[1]

when isMainModule:
    import html, nre, pathnorm, strformat, pages
    from server import initThread
    server.initThread()
    translate.initThread()
    let
        lang = ("en", "it")
        dir = normalizePath(SITE_PATH)
        rx_file = re fmt"(.*{dir}/)(.*$)"
        (p, pp) = buildHomePage("en", false)
        file = "/home/fra/dev/wsl/site/vps/1/cheap-dedicated-server-hosting-price-best-dedicated-hosting-plans.html"
        (filepath, urlpath) = splitUrlPath(rx_file, file)
        pair = (src: "en", trg: "it")
        t_path = file_path / pair.trg / url_path

    let ar = default(Article)
    let d = translateLang(p, file, rx_file, lang, ar = ar)
