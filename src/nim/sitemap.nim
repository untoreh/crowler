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
    result = &"Sitemap: {$(WEBSITE_URL / sitemapxml)}"
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
  $(WEBSITE_URL / "sitemap.xml")

proc sitemapUrl*(topic: string): string =
  ## topic sitemap
  checkTrue topic != "", "Topic is empty."
  $(WEBSITE_URL / topic / "sitemap.xml")

proc sitemapUrl*(topic: string, pagenum: int): string =
  ## page sitemap
  $(WEBSITE_URL / topic / $pagenum / "sitemap.xml")

proc sitemapUrl*(topic: string, pagenum: string): string =
  if topic == "":
    sitemapUrl()
  elif pagenum == "":
    sitemapUrl(topic)
  else:
    var pn: int
    checkTrue topic != "" and pagenum.parseInt(pn) == pagenum.len, "Invalid topic or page number."
    sitemapUrl(topic, pn)

proc sitemapUrl*(topic: string, _: bool): string =
  ## page sitemap
  checkTrue topic != "", "Topic is empty."
  $(WEBSITE_URL / topic / "index.xml")

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
  result.attrs = {"xmlns": xmlNamespace, "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes

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
    syncTopics()
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
    syncTopics()
    var nEntries = 0
    let done = await topicDonePages(topic)
    template langUrl(lang): untyped {.dirty.} = $(WEBSITE_URL / lang / topic / pages[n])
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

proc buildTopicSitemap(topic: string): Future[XmlNode] {.async.} =
    initUrlSet()
    syncTopics()
    let done = await topicDonePages(topic)
    var nEntries = 0
    withPyLock:
        # add the most recent articles first (pages with higher idx)
        for pagenum in countDown(len(done) - 1, 0):
            if unlikely(nEntries > maxEntries):
                warn "Number of URLs for sitemap of topic: {topic} exceeds limit! {nEntries}/{maxEntries}"
                break
            checkTrue pagenum in done, "Mismatching number of pages"
            for a in done[pagenum]:
                addArticleToFeed()

proc buildPageSitemap(topic: string, page: int): Future[XmlNode] {.async.} =
    syncTopics()
    result = newElement("urlset")
    result.attrs = {"xmlns": xmlNamespace, "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes
    let page = await topicPage(topic, page)
    var nEntries = 0
    withPyLock:
        # add the most recent articles first (pages with higher idx)
        for a in page:
          addArticleToFeed()


proc sitemapKey(topic: string): string = topic & "-sitemap.xml"
proc sitemapKey(topic: string, page: string): string = topic & "-" & page & "-sitemap.xml"
proc sitemapKey(topic: string, _: bool): string = topic & "-index.xml"

template checkSitemapSize(sm): untyped = doassert sizeof(sm) * sm.len < maxSize; sm

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

template fetchSiteMap*(topic: string, page: string): untyped = fetchSiteMap(topic, page.parseInt)
proc fetchSiteMap*(topic: string, page: int): Future[string] {.async.} =
  checkTrue topic != "" and page >= 0, "topic and page must be valid"
  return pageCache.lgetOrPut(sitemapKey(topic, $page)):
      let sm = (await buildPageSitemap(topic, page)).toXmlString
      checkSitemapSize sm

proc clearSiteMap*() =
    pageCache.delete(sitemapKey(""))

proc clearSiteMap*(topic: string, all=false) =
    pageCache.delete(topic.sitemapKey)
    pageCache.delete(sitemapKey(topic, on))
    if all:
      for p in 0..<(waitfor lastPageNum(topic)):
        pageCache.delete(sitemapKey(topic, $p))

proc clearSiteMap*(topic: string, pagenum: int) =
    pageCache.delete(sitemapKey(topic, $pagenum))

import karax/[vdom, karaxdsl]
proc sitemapLinks*(topic="", ar = emptyArt[]): seq[VNode] =
  # site wide sitemap (index)
  result.add buildHtml link(rel="sitemap", href=sitemapUrl())
  # articles topic sitemap
  if topic != "":
    result.add buildHtml link(rel="sitemap", href=sitemapUrl(topic))
    result.add buildHtml link(rel="sitemap", href=sitemapUrl(topic, on))
  if ar.page >= 0 and not ar.isEmpty():
    # page sitemap
    result.add buildHtml link(rel="sitemap", href=sitemapUrl(topic, ar.page))

{.pop gcsafe.}

when isMainModule:
  initPy()
  initcache()
  echo waitFor buildTopicPagesSitemap("mini")
  # syncPyLock:
    # echo n
  # pageCache[].
  # echo waitFor fetchSiteMap("mini", on)
