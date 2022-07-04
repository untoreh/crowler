import
    os,
    karax/vdom,
    strutils,
    xmltree,
    asyncdispatch

import
    cfg,
    utils,
    types,
    translate_types,
    translate_tforms,
    translate_tr,
    translate_srv,
    translate

proc translateDom(fc: ptr FileContext, hostname = WEBSITE_DOMAIN): Future[(QueueDom, VNode)] {.async.} =
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
    discard await translate(q.addr, srv, finish = true)
    return (q, otree)

proc translateLang*(tree: vdom.VNode, file, rx: auto, lang: langPair, targetPath = "",
        ar = emptyArt): Future[VNode] {.gcsafe, async.} =
    let
        (filedir, relpath) = splitUrlPath(rx, file)
        t_path = if targetPath == "": filedir / lang.trg / (if relpath == "": "index.html" else: relpath)
                 else: targetPath
    var fc = initFileContext(tree, filedir, relpath, lang, t_path)
    (await translateDom(fc))[1]

proc translateLang*(fc: ptr FileContext, ar = emptyArt): Future[VNode] {.gcsafe, async.} =
    result = (await translateDom(fc))[1]
