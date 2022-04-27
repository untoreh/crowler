import
    xmltree,
    karax/vdom,
    uri,
    sharedtables,
    std/xmlparser,
    sugar,
    os,
    lists,
    std/enumerate

import
    cfg,
    types,
    utils,
    html_misc

type Feed = XmlNode

template `attrs=`(node: XmlNode, code: untyped) =
    node.attrs = code.toXmlAttributes

pragmaVars(XmlNode, threadvar, feed, rss, chann, channTitle, channLink, channDesc)

var feedLinkEl {.threadvar.}: VNode

proc initFeed*() {.gcsafe.} =
    feed = newElement("xml")
    feed.attrs = {"version": "1.0", "encoding": "UTF-8"}

    rss = newElement("rss")
    rss.attrs = {"version": "2.0"}
    feed.add rss

    chann = newElement("channel")
    rss.add chann

    channTitle = newElement("title")
    channTitle.add newText("")
    chann.add channTitle

    channLink = newElement("link")
    channLink.add newText("")
    chann.add channLink

    channDesc = newElement("description")
    channDesc.add newText("")
    chann.add channDesc

    feedLinkEl = newVNode(VNodeKind.link)
    feedLinkEl.setAttr("rel", "alternate")

initFeed()

proc articleItem(ar: Article): XmlNode =
    let item = newElement("item")
    let itemTitle = newElement("title")
    itemTitle.add ar.title
    item.add itemTitle
    let itemLink = newElement("link")
    itemLink.add getArticleUrl(ar)
    item.add itemLink
    let itemDesc = newElement("description")
    itemDesc.add ar.desc
    item.add itemDesc
    return item

proc initFeed(path: string, title: string, description: string, arts: seq[Article]): XmlNode =
    let topic = arts[0].topic
    channTitle[0].text = title
    channLink[0].text = $(WEBSITE_URL / path)
    channDesc[0].text = description
    for ar in arts:
        chann.add articleItem(ar)
    deepCopy(feed)

proc writeFeed*(path: string, fd: XmlNode = feed) =
    debug "rss: writing feed to {path}/feed.xml"
    writeFile(path / "feed.xml", $fd)


proc feedLink*(title, path: string): VNode {.gcsafe.} =
    feedLinkEl.setAttr("title", title)
    feedLinkEl.setAttr("href", $(WEBSITE_URL / path))
    deepCopy(feedLinkEl)

var topicFeeds: SharedTable[string, XmlNode]
init(topicFeeds)

proc fetchFeed(topic: string): XmlNode =
    var tfeed: XmlNode
    tfeed = topicFeeds.lgetOrPut(topic):
        try:
            loadXml(SITE_PATH / topic / "feed.xml")
        except IOError:
            initFeed()
            deepcopy(feed)
    topicFeeds.put(topic, tfeed)

proc feedItems(chann: XmlNode): seq[XmlNode] {.sideEffect.} =
    result = collect:
        for (n, node) in enumerate(chann.items):
            if node.tag == "item":
                chann.delete(n)
                node

proc updateFeed*(topic: string, newArts: seq[Article], dowrite = false) =
    ## Load existing feed for given topic and update the feed (in-memory)
    ## with the new articles provided, it does not write to storage.
    let
        feed = topic.fetchFeed()
        chann = feed.findel("channel")
        itms = chann.feedItems
        arl = itms.len
        narl = newArts.len
        fill = RSS_N_ITEMS - arl
        rem = newArts.len - fill
        shrinked = if rem > 0:
                       itms[0..arl-rem]
                   else: itms
    assert shrinked.len + narl <= RSS_N_ITEMS
    for a in newArts:
        chann.add articleItem(a)
    for item in shrinked:
        chann.add item
    if dowrite:
        writeFeed(SITE_PATH / topic)

template updateFeed*(a: Article) =
    if a.title != "":
        updateFeed(a.topic, @[a])
