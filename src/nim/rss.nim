import
    xmltree,
    karax/vdom,
    uri,
    std/xmlparser,
    lists,
    strformat

import
    cfg,
    types,
    utils,
    cache,
    articles,
    topics,
    pyutils

type Feed = XmlNode

template `attrs=`(node: XmlNode, code: untyped) =
    node.attrs = code.toXmlAttributes

var feed* {.threadvar.}: Feed
threadVars((rss, chann, channTitle, channLink, channDesc, XmlNode))

var feedLinkEl {.threadvar.}: VNode
var topicFeeds* {.threadvar.}: LockLruCache[string, Feed]

proc newFeed(): Feed = newElement("xml")

proc initFeed*() {.gcsafe.} =
    topicFeeds = initLockLruCache[string, Feed](RSS_N_CACHE)
    initCache()
    feed = newFeed()

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

proc drainChannel(chann: XmlNode): seq[XmlNode] {.sideEffect.} =
    var n = 0
    while chann.len > n:
        let node = chann[n]
        if node.tag == "item":
            result.add node
            chann.delete(n)
        else:
            n += 1

proc clearChannel(chann: XmlNode) {.sideEffect.} =
    var n = 0
    while chann.len > n:
        if chann[n].tag == "item":
            chann.delete(n)
        else:
            n += 1

proc articleItem(ar: Article): XmlNode =
    let item = newElement("item")
    let itemTitle = newElement("title")
    itemTitle.add ar.title.escape
    item.add itemTitle
    let itemLink = newElement("link")
    itemLink.add getArticleUrl(ar).escape
    item.add itemLink
    let itemDesc = newElement("description")
    itemDesc.add ar.desc.escape
    item.add itemDesc
    return item

proc getTopicFeed*(topic: string, title: string, description: string, arts: seq[Article]): Feed =
    chann.clearChannel()
    channTitle[0].text = title.escape
    channLink[0].text = ($(WEBSITE_URL / topic)).escape
    channDesc[0].text = description.escape
    for ar in arts:
        chann.add articleItem(ar)
    deepCopy(feed)

proc feedLink*(title, path: string): VNode {.gcsafe.} =
    feedLinkEl.setAttr("title", title)
    feedLinkEl.setAttr("href", $(WEBSITE_URL / path))
    deepCopy(feedLinkEl)

proc feedKey*(topic: string): string = topic & "-feed.xml"

proc update*(tfeed: Feed, topic: string, newArts: seq[Article], dowrite = false) =
    ## Load existing feed for given topic and update the feed (in-memory)
    ## with the new articles provided, it does not write to storage.
    assert not tfeed.isnil
    let
        chann = tfeed.findel("channel")
        itms = chann.drainChannel
        arl = itms.len
        narl = newArts.len
        fill = RSS_N_ITEMS - arl
        rem = newArts.len - fill
        shrinked = if rem > 0 and arl > 0:
                       itms[0..<arl-rem]
                   else: itms
    debug "rss: articles tail len {len(shrinked)}, newarts: {len(newArts)}"
    assert shrinked.len + narl <= RSS_N_ITEMS, fmt"shrinked: {shrinked.len}, newarticles: {narl}"
    for a in newArts:
        chann.add articleItem(a)
    for itm in shrinked:
        chann.add itm
    if dowrite:
        debug "rss: writing feed for topic: {topic}"
        pageCache[][topic.feedKey] = tfeed.toXmlString

template updateFeed*(a: Article) =
    if a.title != "":
        feed.update(a.topic, @[a])

proc fetchFeedString*(topic: string): string =
    pageCache[].lgetOrPut(topic.feedKey):
        let
            topPage = topic.lastPageNum
            prevPage = max(0, topPage - 1)
        var
            arts = getDoneArticles(topic, prevPage)
            tfeed = getTopicFeed(topic, topic, topicDesc(topic), arts)
        if topPage > prevPage:
            arts = getLastArticles(topic)
            tfeed.update(topic, arts, dowrite = false)
        topicFeeds[topic] = tfeed
        tfeed.toXmlString

proc fetchFeed*(topic: string): Feed =
    try:
        topicFeeds[topic]
    except KeyError:
        let feedStr = fetchFeedString(topic)
        try:
            topicFeeds[topic]
        except KeyError:
            topicFeeds.put(topic, parseXml(feedStr))

proc fetchFeedString*(): string =
    pageCache[].lgetOrPut(static(WEBSITE_TITLE.feedKey)):
        var arts: seq[Article]
        let pytopics = loadTopics(cfg.MENU_TOPICS)
        var topicName: string
        for topic in pytopics:
            withPyLock:
                topicName = topic[0].to(string) ## topic holds topic name and description
            let ta = getLastArticles(topicName)
            if ta.len > 0:
                arts.add ta[^1]
        let sfeed = getTopicFeed("", WEBSITE_TITLE, WEBSITE_DESCRIPTION, arts)
        topicFeeds[WEBSITE_TITLE] = sfeed
        sfeed.toXmlString

proc fetchFeed*(): Feed =
    try:
        topicFeeds[WEBSITE_TITLE]
    except:
        let feedStr = fetchFeedString()
        try:
            topicFeeds[WEBSITE_TITLE]
        except KeyError:
            topicFeeds.put(WEBSITE_TITLE, parseXml(feedStr))


initFeed()

when isMainModule:
    syncTopics()
    let topic = "dedi"
    # pageCache[].del(topic)
    # pageCache[].del(WEBSITE_TITLE)
    echo fetchFeed(topic)
