import strformat,
       xmltree,
       uri,
       sugar,
       std/enumerate

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

proc buildSiteSitemap*(topics: seq[string]): XmlNode =
    const xmlNamespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
    result = newElement("sitemapindex")
    result.attrs = {"xmlns": xmlNamespace}.toXmlAttributes
    # result.setAttr("xmlns", )
    for t in topics:
        let
            topicSitemap = newElement("sitemap")
            sitemapLoc = newElement("loc")
            url = ($(WEBSITE_URL / t / "sitemap.xml")).escape()
        topicSitemap.add sitemapLoc
        sitemapLoc.add newText(url)
        result.add topicSitemap

proc buildSiteSitemap*(): XmlNode =
    syncTopics()
    let topics = collect(for (k, _) in topicsCache: k)
    buildSiteSitemap(topics)

proc buildTopicSitemap(topic: string): XmlNode =
    syncTopics()
    result = newElement("urlset")
    result.attrs = {"xmlns": xmlNamespace, "xmlns:xhtml": xhtmlNamespace}.toXmlAttributes
    let done = ut.topic_group(topic)[$topicData.done]
    var n_entries = 0
    for pagenum in done:
        if n_entries > maxEntries:
            warn "Number of URLs for sitemap of topic: {topic} exceeds limit! {n_entries}/{maxEntries}"
            break
        for a in done[pagenum]:
            let url = newElement("url")
            url.attrs = {"loc": getArticleUrl(a, topic).escape}.toXmlAttributes
            for lang in TLangsCodes:
                let link = newElement("xhtml:link")
                link.attrs = {"href": getArticleUrl(a, topic, lang).escape,
                               "hreflang": lang,
                               "rel": "alternate"}.toXmlAttributes
                url.add link
                n_entries += 1
            result.add url


proc sitemapKey(topic: string): string = topic & "-sitemap.xml"

proc fetchSiteMap*(topic: string): string =
    pageCache[].lgetOrPut(topic.sitemapKey):
        let sm = (if topic == "": buildSiteSitemap()
            else: buildTopicSitemap(topic)).toXmlString
        doassert sizeof(sm) * sm.len < maxSize
        sm

{.pop gcsafe.}

when isMainModule:
    initCache()
    echo fetchSiteMap("")
