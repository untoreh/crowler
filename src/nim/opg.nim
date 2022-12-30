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

proc asPrefix(opgKind: Opg): string =
  fmt" {opgKind}: http://ogp.me/ns/{opgKind}#"

proc opgPrefix*(opgKinds: static seq[Opg]): string {.gcsafe.} =
  var res {.threadvar.}: string
  for kind in opgKinds:
    res.add kind.asPrefix

proc metaTag(prop, content: string, base: static[string] = "og"): XmlNode =
  let tag = newXmlTree("meta", @[])
  tag.attrs = {"property": fmt"{base}:{prop}",
                     "content": content}.toXmlAttributes()
  return tag

proc opgBasic(title, tp, url, image: string, prefix = ""): seq[XmlNode] =
  if prefix != "":
    result.add metaTag(fmt"{prefix}:title", title)
    result.add metaTag(fmt"{prefix}:type", tp)
    result.add metaTag(fmt"{prefix}:url", url)
    result.add metaTag(fmt"{prefix}:image", image)
  else:
    result.add metaTag("title", image)
    result.add metaTag("type", image)
    result.add metaTag("url", image)
    result.add metaTag("image", image)

proc opgOptional(description, siteName, locale, audio, video,
    determiner: string): seq[XmlNode] =
  if description.isSomething: result.add metaTag("description", description)
  if siteName.isSomething: result.add metaTag("siteName", siteName)
  if locale.isSomething: result.add metaTag("locale", locale)
  if audio.isSomething: result.add metaTag("audio", audio)
  if video.isSomething: result.add metaTag("video", video)
  if determiner.isSomething: result.add metaTag("determiner", determiner)

proc toString(res: seq[XmlNode]): string {.gcsafe.} = collect(for t in res: $t).join

proc opgTags(title, tp, url,
             image: string,
             description = "",
             siteName = "",
             locale = "",
             audio = "",
             video = "",
             determiner = "",
             prefix = ""): seq[XmlNode] {.gcsafe.} =
  ## Generates an HTML String containing opengraph meta result for one item.
  var result = opgBasic(title, tp, url, image, prefix)
  result.add opgOptional(description, siteName, locale, audio, video, determiner)
  return result

proc opgStructure*(prop, url, secureUrl, mime, width, height, alt: string): seq[XmlNode] =
  ## Writes the additional metadata structures to the specified PROP.
  result.add metaTag(fmt"{prop}:url", url)
  if secureUrl.isSomething: result.add metaTag(fmt"{prop}:secure_url", secureUrl)
  if mime.isSomething: result.add metaTag(fmt"{prop}:type", mime)
  if prop == "audio": return
  if width.isSomething: result.add metaTag(fmt"{prop}:width", width)
  if height.isSomething: result.add metaTag(fmt"{prop}:height", height)
  if alt.isSomething: result.add metaTag(fmt"{prop}:alt", alt)

proc twitterMeta(prop, content: string): XmlNode =
  let tag = newXmlTree("meta", @[])
  tag.attrs = {"property": fmt"twitter:{prop}",
                     "content": content}.toXmlAttributes()
  return tag

proc opgTwitter*(prop, content: string): XmlNode =
  ## Twitter card meta tag
  metaTag(prop, content, base = "twitter")

proc opgPage*(a: Article): seq[XmlNode] =
  let locale = static(DEFAULT_LOCALE)
  let
    tp = static("article")
    url = getArticleUrl(a)
    siteName = config.websiteTitle
  result = opgTags(a.title, tp, url, a.imageUrl, a.desc, siteName, locale, prefix = "article")
  for t in a.tags:
    result.add metaTag("article:tag", t)
  result.add metaTag("article:author", a.author)
  result.add metaTag("article:published_time", $a.pubTime)
  result.add metaTag("article:section", a.desc)
  # result.add metaTag("article:modified_time", a.pubTime)
  # result.add metaTag("article:expiration_time", a.pubTime)
  result.add twitterMeta("card", "summary")
  result.add twitterMeta("creator", twitterUrl[])

proc opgPage*(title: string, description: string,
    path: string): seq[XmlNode] {.gcsafe.} =
  let locale = static(DEFAULT_LOCALE)
  let
    title = title
    tp = static("website")
    url = $(config.websiteUrl / path)
  result = opgTags(title, tp, url, "", description, "", locale)
  result.add twitterMeta("card", "summary")
  result.add twitterMeta("creator", twitterUrl[])
