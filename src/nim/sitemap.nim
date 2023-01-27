import strformat,
       xmltree,
       uri,
       sugar,
       chronos
from strutils import parseInt

import cfg,
       types,
       utils,
       topics,
       articles,
       translate_types,
       cache

const
  sitemapxml = "sitemap.xml"
  maxEntries = 50_000
  maxSize = 50 * 1024 * 1024
  maxIndex = 500

{.push gcsafe.}

proc buildRobots*(disallow: seq[string] = @[]): string =
  result = &"Sitemap: {$(config.websiteUrl / sitemapxml)}"
  result.add "\nUser-Agent: *"
  if disallow.len > 0:
    for path in disallow:
      result.add &"\nDisallow: {path}"
  else:
    result.add "\nDisallow:"

const
  xmlNamespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
  xhtmlNamespace = "http://www.w3.org/1999/xhtml"

import std/parseutils

{.push inline.}

proc sitemapUrl*(): string =
  ## site sitemap
  $(config.websiteUrl / "sitemap.xml")

proc sitemapUrl*(topic: string): string =
  ## topic sitemap
  checkTrue topic != "", "Topic is empty."
  $(config.websiteUrl / topic / "sitemap.xml")

proc sitemapUrl*(topic: string, pagenum: int): string =
  ## page sitemap
  $(config.websiteUrl / topic / $pagenum / "sitemap.xml")

proc sitemapUrl*(topic: string, pagenum: string): string =
  if topic == "":
    sitemapUrl()
  elif pagenum == "":
    sitemapUrl(topic)
  else:
    var pn: int
    checkTrue topic != "" and pagenum.parseInt(pn) == pagenum.len,
        fmt"Invalid topic({topic}) or page number({pagenum})."
    sitemapUrl(topic, pn)

proc sitemapUrl*(topic: string, _: bool): string =
  ## page sitemap
  checkTrue topic != "", "Topic is empty."
  $(config.websiteUrl / topic / "index.xml")

{.pop.}

template sitemapEl(path): untyped =
  let
    el = newElement("sitemap")
    loc = newElement("loc")
    url = path.escape()
  el.add loc
  loc.add newText(url)
  result.add el
  el

template initUrlSet() =
  result = newElement("urlset")
  result.attrs = {"xmlns": xmlNamespace,
      "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes

template initSitemapIndex() =
  result = newElement("sitemapindex")
  result.attrs = {"xmlns": xmlNamespace}.toXmlAttributes

proc buildSiteSitemap*(topics: seq[string]): Future[XmlNode] {.async.} =
  initSitemapIndex()
  var nTopics: int
  for n in countDown(topics.len - 1, 0):
    let t = topics[n]
    if (await t.hasArticles):
      discard sitemapEl(sitemapUrl(t))
      nTopics.inc
      if unlikely(nTopics > maxEntries):
        break

proc buildSiteSitemap*(): Future[XmlNode] {.async.} =
  let topics = collect(for (k, _) in topicsCache: k)
  return await buildSiteSitemap(topics)

template addLangs(el, getLocLang) =
  for lang in TLangsCodes:
    let link = newElement("xhtml:link")
    link.attrs = {"href": getLocLang(lang).escape,
                "hreflang": lang,
                "rel": "alternate"}.toXmlAttributes
    el.add link
    nEntries.inc

template addUrlToFeed(getLoc, getLocLang) =
  if unlikely(nEntries > maxEntries):
    warn "Number of URLs for sitemap of topic: {topic} exceeds limit! {nEntries}/{maxEntries}"
    break
  let
    url = newElement("url")
    loc = newElement("loc")
  loc.add getLoc().escape.newText
  url.add loc
  addLangs(url, getLocLang)
  result.add url

proc buildTopicPagesSitemap*(topic: string): Future[XmlNode] {.async.} =
  initSitemapIndex()
  var nEntries = 0
  let done = await topicDonePages(topic)
  template langUrl(lang): untyped {.dirty.} = $(config.websiteUrl / lang / topic /
      pages[n])
  withPyLock:
    # add the most recent articles first (pages with higher idx)
    let pages = pybi[].list(done.keys()).to(seq[string])
    for n in countDown(pages.len - 1, 0):
      if not (await isEmptyPage(topic, pages[n].parseInt, false)):
        discard sitemapUrl(topic, pages[n]).sitemapEl

template addArticleToFeed() =
  template baseUrl(): untyped =
    getArticleUrl(a, topic)

  template langUrl(lang): untyped =
    getArticleUrl(a, topic, lang)

  if not a.isValidArticlePy:
    continue

  addUrlToFeed(baseUrl, langUrl)

template addPageToFeed() =
  template baseUrl(): untyped =
    $(config.websiteUrl / topic / $pagenum)
  template langUrl(lang): untyped =
    $(config.websiteUrl / lang / topic / $pagenum)
  addUrlToFeed(baseUrl, langUrl)

proc buildTopicSitemap(topic: string): Future[XmlNode] {.async.} =
  initUrlSet()
  let done = await topicDonePages(topic)
  var from_page = 0
  var nEntries = 0
  withPyLock:
    # add the most recent articles first (pages with higher idx)
    # from last 10 pages
    for pagenum in countDown(len(done) - 1, len(done) - 2):
      if unlikely(nEntries > maxEntries):
        warn "Number of URLs for sitemap of topic: {topic} exceeds limit! {nEntries}/{maxEntries}"
        break
      checkTrue pagenum in done, "Mismatching number of pages"
      for a in done[pagenum]:
        addArticleToFeed()
    from_page = len(done) - 3
  for pagenum in countDown(from_page, 0):
    addPageToFeed()


proc buildPageSitemap(topic: string, page: int): Future[XmlNode] {.async.} =
  result = newElement("urlset")
  result.attrs = {"xmlns": xmlNamespace,
      "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes
  let page = await topicPage(topic, page)
  var nEntries = 0
  withPyLock:
    # add the most recent articles first (pages with higher idx)
    for a in page:
      addArticleToFeed()


proc sitemapKey(topic: string): string = topic & "-sitemap.xml"
proc sitemapKey(topic: string, page: string): string = topic & "-" & page & "-sitemap.xml"
proc sitemapKey(topic: string, _: bool): string = topic & "-index.xml"

template checkSitemapSize(sm): untyped =
  if sizeof(sm) * sm.len < maxSize:
    block:
      let sz {.inject.} = sizeof(sm) * sm.len
      warn "Sitemap exceeding max size! ({sz} > {maxSize})"
  sm


proc fetchSiteMap*(): Future[string] {.async.} =
  return pageCache.lgetOrPut(sitemapKey("")):
    let sm = (await buildSiteSitemap()).toXmlString
    checkSitemapSize sm

proc fetchSiteMap*(topic: string): Future[string] {.async.} =
  checkTrue topic.len > 0, "topic must be valid"
  return pageCache.lgetOrPut(topic.sitemapKey):
    let sm = (await buildTopicSitemap(topic)).toXmlString
    checkSitemapSize sm

proc fetchSiteMap*(topic: string, _: bool): Future[string] {.async.} =
  checkTrue topic.len > 0, "topic must be valid"
  return pageCache.lgetOrPut(sitemapKey(topic, on)):
    let sm = (await buildTopicPagesSitemap(topic)).toXmlString
    checkSitemapSize sm

template fetchSiteMap*(topic: string, page: string): untyped = fetchSiteMap(
    topic, page.parseInt)
proc fetchSiteMap*(topic: string, page: int): Future[string] {.async.} =
  checkTrue topic != "" and page >= 0, "topic and page must be valid"
  return pageCache.lgetOrPut(sitemapKey(topic, $page)):
    let sm = (await buildPageSitemap(topic, page)).toXmlString
    checkSitemapSize sm

proc clearSiteMap*() =
  pageCache.delete(sitemapKey(""))

proc clearSiteMap*(topic: string, all = false) =
  pageCache.delete(topic.sitemapKey)
  pageCache.delete(sitemapKey(topic, on))
  if all:
    for p in 0..<(waitfor lastPageNum(topic)):
      pageCache.delete(sitemapKey(topic, $p))

proc clearSiteMap*[T](topic: string, pagenum: T) =
  pageCache.delete(sitemapKey(topic, $pagenum))

import karax/[vdom, karaxdsl]
proc sitemapLinks*(topic = "", ar = emptyArt): seq[VNode] =
  # site wide sitemap (index)
  result.add buildHtml link(rel = "sitemap", href = sitemapUrl())
  # articles topic sitemap
  if topic != "":
    result.add buildHtml link(rel = "sitemap", href = sitemapUrl(topic))
    result.add buildHtml link(rel = "sitemap", href = sitemapUrl(topic, on))
  if ar.page >= 0 and not ar.isEmpty():
    # page sitemap
    result.add buildHtml link(rel = "sitemap", href = sitemapUrl(topic, ar.page))

{.pop gcsafe.}

