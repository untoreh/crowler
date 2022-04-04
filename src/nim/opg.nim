import
    strutils,
    strformat,
    tables,
    xmltree

import cfg,
       types,
       utils

const basePrefix = "og: https://ogp.me/ns#"


type Opg = enum
    article, website, book, profile, video, music

let prefixCache = initTable[seq[Opg], string]()
var opgTags = newSeq[XmlNode]()

proc asPrefix(opgKind: Opg): string =
    fmt" {opgKind}: http://ogp.me/ns/{opgKind}#"

proc opgPrefix(opgKinds: seq[Opg]): string =
    try:
        result = prefixCache[opgKinds]
    except:
        var result = basePrefix
        for kind in opgKinds:
            result.add kind.asPrefix
        prefixCache[opgKinds] = result

proc addMetaTag(prop, content: string, base: static[string] = "og") =
    let tag = newXmlTree("meta", @[])
    tag.attrs = {"property": fmt"{base}:{prop}",
                       "content": content}.toXmlAttributes()
    opgTags.add(tag)

proc opgBasic(title, tp, url, image: string, prefix="") =
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

proc fillOpgTags(title, tp, url, image, description="", siteName="", locale="", audio="", video="", determiner="") =
    ## Generates an HTML String containing opengraph meta tags for one item.
    opgBasic(title, tp, url, image)
    opgOptional(description, siteName, locale, audio, video, determiner)

template getOpgTags(args: untyped): string =
    fillOpgTags(args)
    for t in opgTags:
        result.add $t

proc opgStructure(prop, url, secureUrl, mime, width, height, alt: string) =
    ## Writes the additional metadata structures to the specified PROP.
    addMetaTag(fmt"{prop}:url", url)
    if secureUrl.isSomething: addMetaTag(fmt"{prop}:secure_url", secureUrl)
    if mime.isSomething: addMetaTag(fmt"{prop}:type", mime)
    if prop == "audio": return
    if width.isSomething: addMetaTag(fmt"{prop}:width", width)
    if height.isSomething: addMetaTag(fmt"{prop}:height", height)
    if alt.isSomething: addMetaTag(fmt"{prop}:alt", alt)

proc opgArticle(title, tp, url, image, author: string, tag: seq[string] = @[], section="", ctime, mtime, etime ="") =
    ## Write meta tags for an article object type.
    opgBasic(title, tp, url, image, prefix="article")
    addMetaTag("article:author", author)
    addMetaTag("article:published_time", ctime)
    addMetaTag("article:modiefied_time", mtime)
    if etime.isSomething: addMetaTag("article:modiefied_time", mtime)
    if section.isSomething: addMetaTag("article:section", section)
    for t in tag:
        addMetaTag("article:tag", t)

proc twitterMeta() =
    let tag = newXmlTree("meta", @[])
    tag.attrs = {"property": fmt"twitter:{prop}",
                       "content": content}.toXmlAttributes()
    opgTags.add(tag)

proc opgTwitter(prop, content: string) =
    ## Twitter card meta tags
    addMetaTag(prop, content, base="twitter")

proc opgPage(a: Article): string =
    let locale = static(DEFAULT_LOCALE)
    let
        title = a.title
        description = a.description
        tp = static("article")
        url = getArticleUrl(a)
        siteName = static(WEBSITE_TITLE)
    twitterMeta("card", "summary")
    twitterMeta("creator", TWITTER_HANDLE)
    getOpgTags(title, tp, url, imageUrl, description, siteName, locale)

proc opgPage(title: string, description: string, path: string): string =
    let locale = static(DEFAULT_LOCALE)
    let
        title = a.title
        tp = static("website")
        url = $(WEBSITE_URL / path)
    twitterMeta("card", "summary")
    twitterMeta("creator", TWITTER_HANDLE)
    getOpgTags(title, tp, url, "", description, "", locale)
