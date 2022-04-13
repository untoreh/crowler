import
    karax/[vdom, karaxdsl],
    std/with,
    uri,
    sugar,
    sets,
    os,
    nre,
    strutils,
    algorithm,
    tables

import
    cfg,
    utils,
    translate_types,
    html_misc

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

var sortedLanguages = (
    collect(for lang in TLangs: lang),
    SLang.code
)
sortedLanguages[0].sort

const countryLangs = {
    "ar": "sa",
    "en": "gb",
    "el": "gr",
    "hi": "in",
    "pa": "in",
    "ja": "jp",
    "jw": "id",
    "bn": "bd",
    "tl": "ph",
    "zh": "cn",
    "ko": "kr",
    "uk": "ua",
    "zu": "za",
    "vi": "vn",
    "ur": "pk",
    "sv": "se"
}.toTable
proc langToCountry(lang: string): string {.inline.} = countryLangs.getOrDefault(lang, lang)

const langCssClasses = "flag flag-"
proc langsList*(path: string): VNode =
    buildHtml(ul(class = "lang-list")):
        for (name, code) in sortedLanguages[0]:
            let pathCode = if code == sortedLanguages[1]: ""
                           else: code
            a(class = "lang-link lang-"&code, href = pathLink(path, pathcode)):
                span(class = langCssClasses&langToCountry(code))
                text name
