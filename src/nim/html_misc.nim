import os,
       uri,
       strutils,
       strformat,
       nimpy,
       karax/[vdom, karaxdsl],
       sets,
       chronos,
       sequtils # zip

import
  cfg,
  types,
  utils,
  topics,
  articles,
  search,
  shorturls

var
  facebookUrl* {.threadvar.}: string
  twitterUrl* {.threadvar.}: string

proc initSocial*() {.gcsafe.} =
  syncPyLock:
    facebookUrl = site.fb_page_url.to(string)
    twitterUrl = site.twitter_url.to(string)

proc pathLink*(path: string, code = "", rel = true,
    amp = false): string {.gcsafe.} =
  let (dir, name, _) = path.splitFile
  let name_cleaned = name.replace(sre "(index|404)$", "")
  $(
      (if rel: baseUri else: config.websiteUrl) /
      (if amp: "amp/" else: "") /
      code /
      dir /
      name_cleaned
      )


proc buildImgUrl*(ar: Article; cls = "image-link", defsrc = ""): VNode =
  var srcsetstr, bsrc: string
  let defaultImgOnError = fmt"this.onerror=null; this.style['filter'] = 'opacity(0.1);'; this.src='{defsrc}'"
  if ar.imageUrl != "" and not ar.imageUrl.endswith(".ico"):
    # add `?` because chromium doesn't treat it as a string otherwise
    let burl = "?u=" & ar.imageUrl.toBString(true)
    bsrc = "//" & $(config.websiteUrl_IMG / IMG_SIZES[1] / burl)
    for (view, size) in zip(IMG_VIEWPORT, IMG_SIZES):
      srcsetstr.add "//" & $(config.websiteUrl_IMG / size / burl)
      srcsetstr.add " " & view & ","

  let i = buildHtml(img(class = "", srcset = srcsetstr, loading = "lazy"))
  if bsrc.len > 0:
    i.setAttr("src", bsrc)
  else:
    i.setAttr("src", defsrc)
    i.setAttr("style", "filter: opacity(0.1);")

  i.setAttr("onerror", defaultImgOnError)
  let link =
    buildHtml(a(class = cls, href = ar.imageOrigin, target = "_blank", alt = "Post image source."))
  link.add i
  link

proc fromSearchResult*(pslug: string): Future[Article] {.async.} =
  ## Construct an article from a stored search result
  let
    s = pslug.split("/")
    topic = s[0]
    page = s[1]
    slug = s[2]

  debug "html: fromSearchResult - {pslug}"
  if topic != "" and topic in topicsCache:
    result = await getArticle(topic, page, slug)


import xmltree
import html_entities
import strformat
const selfClosingTags = ["area", "base", "br", "col", "embed", "r", "img", "input", "link", "meta",
        "param", "source", "track", "wbr", ].toHashSet

func withClosingHtmlTag*(el: XmlNode): string =
  ## `htmlparser` package seems to avoid closing tags for elements with no content
  result = ($el).entToUtf8
  if el.kind == xnElement and (result.endsWith("/>") or
                               (result.endsWith(fmt"></{el.tag}>") and not (
                                 el.tag in selfClosingTags))):
    result[^2] = ' '
    result.add "</" & el.tag & ">"
