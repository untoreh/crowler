import
    strutils,
    strformat,
    tables,
    xmltree,
    uri,
    macros,
    sugar,
    karax/vdom

import cfg,
       types,
       utils,
       html_misc,
       articles

const basePrefix* = "og: https://ogp.me/ns#"


type Opg* = enum
    article, website, book, profile, video, music

let prefixCache* = initTable[static seq[Opg], static string]()
var opgTags {.threadvar.}: seq[XmlNode]
proc initOpg*() =
    opgTags = newSeq[XmlNode]()
initOpg()

proc asPrefix(opgKind: Opg): string =
    fmt" {opgKind}: http://ogp.me/ns/{opgKind}#"

proc opgPrefix*(opgKinds: static seq[Opg]): string {.gcsafe.} =
    var res {.threadvar.}: string
    for kind in opgKinds:
        res.add kind.asPrefix

proc addMetaTag(prop, content: string, base: static[string] = "og") =
    let tag = newXmlTree("meta", @[])
    tag.attrs = {"property": fmt"{base}:{prop}",
                       "content": content}.toXmlAttributes()
    opgTags.add(tag)

proc opgBasic(title, tp, url, image: string, prefix = "") =
    if prefix != "":
        addMetaTag(fmt"{prefix}:title", title)
        addMetaTag(fmt"{prefix}:type", tp)
        addMetaTag(fmt"{prefix}:url", url)
        addMetaTag(fmt"{prefix}:image", image)
    else:
        addMetaTag("title", image)
        addMetaTag("type", image)
        addMetaTag("url", image)
        addMetaTag("image", image)

proc opgOptional(description, siteName, locale, audio, video, determiner: string) =
    if description.isSomething: addMetaTag("description", description)
    if siteName.isSomething: addMetaTag("siteName", siteName)
    if locale.isSomething: addMetaTag("locale", locale)
    if audio.isSomething: addMetaTag("audio", audio)
    if video.isSomething: addMetaTag("video", video)
    if determiner.isSomething: addMetaTag("determiner", determiner)

proc opgTagsToString(): string {.gcsafe.} = collect(for t in opgTags: $t).join

proc fillOpgTags(title, tp, url, image: string, description = "", siteName = "", locale = "", audio = "",
        video = "", determiner = ""): auto {.gcsafe.} =
    ## Generates an HTML String containing opengraph meta tags for one item.
    opgBasic(title, tp, url, image)
    opgOptional(description, siteName, locale, audio, video, determiner)
    opgTagsToString().verbatim


proc opgStructure*(prop, url, secureUrl, mime, width, height, alt: string) =
    ## Writes the additional metadata structures to the specified PROP.
    addMetaTag(fmt"{prop}:url", url)
    if secureUrl.isSomething: addMetaTag(fmt"{prop}:secure_url", secureUrl)
    if mime.isSomething: addMetaTag(fmt"{prop}:type", mime)
    if prop == "audio": return
    if width.isSomething: addMetaTag(fmt"{prop}:width", width)
    if height.isSomething: addMetaTag(fmt"{prop}:height", height)
    if alt.isSomething: addMetaTag(fmt"{prop}:alt", alt)

proc opgArticle*(title, tp, url, image, author: string, tag: seq[string] = @[], section = "", ctime,
        mtime, etime = "") =
    ## Write meta tags for an article object type.
    opgBasic(title, tp, url, image, prefix = "article")
    addMetaTag("article:author", author)
    addMetaTag("article:published_time", ctime)
    addMetaTag("article:modiefied_time", mtime)
    if etime.isSomething: addMetaTag("article:modiefied_time", mtime)
    if section.isSomething: addMetaTag("article:section", section)
    for t in tag:
        addMetaTag("article:tag", t)

proc twitterMeta(prop, content: string) =
    let tag = newXmlTree("meta", @[])
    tag.attrs = {"property": fmt"twitter:{prop}",
                       "content": content}.toXmlAttributes()
    opgTags.add(tag)

proc opgTwitter*(prop, content: string) =
    ## Twitter card meta tags
    addMetaTag(prop, content, base = "twitter")

proc opgPage*(a: Article): VNode =
    let locale = static(DEFAULT_LOCALE)
    let
        tp = static("article")
        url = getArticleUrl(a)
        siteName = static(WEBSITE_TITLE)
    twitterMeta("card", "summary")
    twitterMeta("creator", twitterUrl[])
    fillOpgTags(a.title, tp, url, a.imageUrl, a.desc, siteName, locale)

proc opgPage*(title: string, description: string, path: string): VNode {.gcsafe.} =
    let locale = static(DEFAULT_LOCALE)
    let
        title = title
        tp = static("website")
        url = $(WEBSITE_URL / path)
    twitterMeta("card", "summary")
    twitterMeta("creator", twitterUrl[])
    fillOpgTags(title, tp, url, "", description, "", locale)
