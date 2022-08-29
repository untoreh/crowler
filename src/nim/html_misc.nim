import os,
       nre,
       uri,
       strutils,
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
  facebookUrl*: ptr string
  twitterUrl*: ptr string

proc initSocial*() {.gcsafe.} =
  syncPyLock:
    facebookUrl = create(string)
    facebookUrl[] = site[].fb_page_url.to(string)
    twitterUrl = create(string)
    twitterUrl[] = site[].twitter_url.to(string)

proc pathLink*(path: string, code = "", rel = true,
    amp = false): string {.gcsafe.} =
  let (dir, name, _) = path.splitFile
  let name_cleaned = name.replace(sre "(index|404)$", "")
  $(
      (if rel: baseUri else: WEBSITE_URL) /
      (if amp: "amp/" else: "") /
      code /
      dir /
      name_cleaned
      )

proc buildImgUrl*(ar: Article; cls = "image-link"): VNode =
  var srcsetstr, bsrc: string
  if ar.imageUrl != "":
    # add `?` because chromium doesn't treat it as a string otherwise
    let burl = "?" & ar.imageUrl.toBString(true)
    bsrc = "//" & $(WEBSITE_URL_IMG / IMG_SIZES[1] / burl)
    for (view, size) in zip(IMG_VIEWPORT, IMG_SIZES):
      srcsetstr.add "//" & $(WEBSITE_URL_IMG / size / burl)
      srcsetstr.add " " & view & ","
  buildHtml(a(class = cls, href = ar.imageOrigin, target = "_blank",
            alt = "Post image source.")):
    img(class = "", src = bsrc, srcset = srcsetstr,
        loading = "lazy")

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

proc buildRelated*(a: Article): Future[VNode] {.async.} =
  ## Get a list of related articles by querying search db with tags and title words
  # try a full tag (or title) search first, then try word by word
  var kws = a.tags
  kws.add(a.title)
  for tag in a.tags:
    kws.add strutils.split(tag)
  kws.add(strutils.split(a.title))

  result = newVNode(VNodeKind.ul)
  result.setAttr("class", "related-posts")
  var c = 0
  var related: HashSet[string]
  for kw in kws:
    if kw.len < 3:
      continue
    let sgs = await query(a.topic, kw.toLower, limit = N_RELATED)
    logall "html: suggestions {sgs}, from kw: {kw}"
    # if sgs.len == 1 and sgs[0] == "//":
    #     return
    for sg in sgs:
      let relart = await fromSearchResult(sg)
      if (relart.isnil or (relart.slug in related or relart.slug == "")):
        continue
      else:
        related.incl relart.slug
      let
        entry = newVNode(li)
        link = newVNode(VNodeKind.a)
        img = buildImgUrl(relart, "related-img")
      link.setAttr("href", getArticleUrl(relart))
      link.value = relart.title
      link.add newVNode(VNodeKind.text)
      link[0].value = relart.title
      entry.add img
      entry.add link
      result.add entry
      c += 1
    if c >= cfg.N_RELATED:
      return

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
