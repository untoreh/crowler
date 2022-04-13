import
    karax/vdom,
    std/with,
    uri,
    sugar,
    sets,
    os,
    nre,
    strutils

import
    cfg,
    utils,
    translate_types

var langTmpUri: Uri
langTmpUri.opaque = false

proc langUrl(code, url: string, prefix = "/"): string =
    parseUri(url, langTmpUri)
    langTmpUri.path = prefix & code & langTmpUri.path
    $langTmpUri

proc makeLangLink(code, url: string): VNode =
    result = newVNode(VNodeKind.link)
    let href = langUrl(code, url)
    with result:
        setAttr("rel", "alternate")
        setAttr("hreflang", code)
        setAttr("href", href)

let langLinks = collect:
    for lang in TLangs:
        makeLangLink(lang.code, "/")

proc setLangLinks*(url: string) =
    for link in langLinks:
        let code = link.getAttr("hreflang")
        # TODO: this can be optimized
        link.setAttr("href", langUrl(code, url))

proc langLinksNodes*(path: string, rel: static bool = false): seq[VNode] =
    let srcUrl = if rel: path
                 else: $(WEBSITE_URL / path)
    setLangLinks(srcUrl)
    langLinks

proc langLinksHtml*(path: string, rel: static bool = false): string =
    langLinksNodes(path, rel)
    let res = collect:
        for l in langLinks:
            $l
    join(res)

proc ldjLanguages*(): seq[string] = collect(for (lang, _) in TLangs: lang)
