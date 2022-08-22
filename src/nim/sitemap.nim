import strformat,
       xmltree,
       uri,
       sugar,
       chronos

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

proc buildSiteSitemap*(topics: seq[string]): Future[XmlNode] {.async.} =
  const xmlNamespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
  result = newElement("sitemapindex")
  result.attrs = {"xmlns": xmlNamespace}.toXmlAttributes
  # result.setAttr("xmlns", )
  for t in topics:
    if (await t.hasArticles):
      let
        topicSitemap = newElement("sitemap")
        sitemapLoc = newElement("loc")
        url = ($(WEBSITE_URL / t / "sitemap.xml")).escape()
      topicSitemap.add sitemapLoc
      sitemapLoc.add newText(url)
      result.add topicSitemap

proc buildSiteSitemap*(): Future[XmlNode] {.async.} =
    await syncTopics()
    let topics = collect(for (k, _) in topicsCache: k)
    return await buildSiteSitemap(topics)

proc buildTopicSitemap(topic: string): Future[XmlNode] {.async.} =
    await syncTopics()
    result = newElement("urlset")
    result.attrs = {"xmlns": xmlNamespace, "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes
    let done = await topicDonePages(topic)
    var n_entries = 0
    withPyLock:
        for pagenum in done:
            if n_entries > maxEntries:
                warn "Number of URLs for sitemap of topic: {topic} exceeds limit! {n_entries}/{maxEntries}"
                break
            for a in done[pagenum]:
                if pyisnone(a):
                    continue
                let
                    url = newElement("url")
                    loc = newElement("loc")
                loc.add getArticleUrl(a, topic).escape.newText
                url.add loc
                for lang in TLangsCodes:
                    let link = newElement("xhtml:link")
                    link.attrs = {"href": getArticleUrl(a, topic, lang).escape,
                                "hreflang": lang,
                                "rel": "alternate"}.toXmlAttributes
                    url.add link
                    n_entries += 1
                result.add url


proc sitemapKey(topic: string): string = topic & "-sitemap.xml"

proc fetchSiteMap*(topic: string): Future[string] {.async.} =
    return pageCache[].lgetOrPut(topic.sitemapKey):
        let sm = (if topic == "": await buildSiteSitemap()
            else: await buildTopicSitemap(topic)).toXmlString
        doassert sizeof(sm) * sm.len < maxSize
        sm

proc clearSiteMap*(topic: string) {.gcsafe.} =
    pageCache[].del(topic.sitemapKey)

{.pop gcsafe.}

when isMainModule:
    initCache()
