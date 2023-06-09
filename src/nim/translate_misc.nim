import
    karax/[vdom, karaxdsl],
    std/with,
    uri,
    sugar,
    sets,
    os,
    strutils,
    algorithm,
    tables

import
    cfg,
    types,
    utils,
    translate_types,
    ldj

export SLang
var langTmpUri {.threadvar.}: Uri

proc langUrl(code, url: string, prefix = "/"): string {.gcsafe.} =
    parseUri(url, langTmpUri)
    langTmpUri.opaque = false
    langTmpUri.path = prefix & code & langTmpUri.path
    $langTmpUri

proc makeLangLink(code, url: string): VNode =
    result = newVNode(VNodeKind.link)
    let href = langUrl(code, url)
    with result:
        setAttr("rel", "alternate")
        setAttr("hreflang", code)
        setAttr("href", href)

var langLinks {.threadvar.}: seq[VNode]
langLinks = collect:
    for lang in TLangs:
        makeLangLink(lang.code, "/")

proc setLangLinks*(url: string) {.gcsafe.} =
    for link in langLinks:
        let code = link.getAttr("hreflang")
        # TODO: this can be optimized
        link.setAttr("href", langUrl(code, url))

proc langLinksNodes*(path: string, rel: static bool = false): seq[VNode] {.gcsafe.} =
    let srcUrl = when rel: path
                 else: $(config.websiteUrl / path)
    setLangLinks(srcUrl)
    langLinks

proc langLinksHtml*(path: string, rel: static bool = false): string =
    langLinksNodes(path, rel)
    let res = collect:
        for l in langLinks:
            $l
    join(res)

proc ldjLanguages*(): seq[string] = collect(for (lang, _) in TLangs: lang)

const sortedLanguages = block:
                          var s = (collect(for lang in TLangs: lang), SLang.code)
                          s[0].sort
                          s

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
    "zh-CN": "cn",
    "ko": "kr",
    "uk": "ua",
    "zu": "za",
    "vi": "vn",
    "ur": "pk",
    "sv": "se"
}.toTable
proc langToCountry(lang: string): string {.inline.} = countryLangs.getOrDefault(lang, lang)

const langCssClasses = "flag flag-"
proc langsList*(path: string): VNode {.gcsafe.} =
    buildHtml(ul(class = "lang-list")):
        for (name, code) in sortedLanguages[0]:
            let pathCode = if code == sortedLanguages[1]: ""
                        else: code
            a(class = "lang-link lang-"&code, href = pathLink(path, pathcode)):
                span(class = langCssClasses & langToCountry(code))
                text name

proc ldjTrans*(relpath, srcurl, trgurl: string, lang: langPair, a: Article): VNode =
    ldj.translation(srcurl, trgurl, lang.srcLangName,
                    title=a.title,
                    mtime=($a.pubDate),
                    selector=".post-content",
                    description=a.desc,
                    keywords=a.tags,
                    image=a.imageUrl,
                    headline=a.title,
                    translator_name="Google Translate",
                    translator_url="http://google.translate.com").asVNode
