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

let feed = newElement("xml")
feed.attrs = {"version": "1.0", "encoding": "UTF-8"}
let rss = newElement("rss")
rss.attrs = {"version": "2.0"}
feed.add rss
let chann = newElement("channel")
rss.add chann
let channTitle = newElement("title")
channTitle.add newText("")
chann.add channTitle
let channLink = newElement("link")
channLink.add newText("")
chann.add channLink
let channDesc = newElement("description")
channDesc.add newText("")
chann.add channDesc

proc articleItem(ar: Article): XmlNode =
    let item = newElement("item")
    let itemTitle = newElement("title")
    itemTitle.text = ar.title
    item.add itemTitle
    let itemLink = newElement("link")
    itemLink.text = getArticleUrl(ar)
    item.add itemLink
    let itemDesc = newElement("description")
    itemDesc.text = ar.desc
    item.add itemDesc
    return item

proc initFeed(path: string, title: string, description: string, arts: seq[Article]): XmlNode =
    let topic = arts[0].topic
    channTitle[0].text = title
    channLink[0].text = $(WEBSITE_URL / path)
    channDesc[0].text = description
    for ar in arts:
        chann.add articleItem(ar)

proc writeFeed*(path: string, fd: XmlNode = feed) = writeFile(path / "feed.xml", $fd)

let feedLinkEl = newVNode(VNodeKind.link)
feedLinkEl.setAttr("rel", "alternate")
feedLinkEl.setAttr("type", "application/rss+xml")

proc feedLink*(title, path: string): VNode =
    feedLinkEl.setAttr("title", title)
    feedLinkEl.setAttr("href", $(WEBSITE_URL / path))
    deepCopy(feedLinkEl)

var topicFeeds: SharedTable[string, XmlNode]
init(topicFeeds)

proc fetchFeed(topic: string): XmlNode =
    var feed: XmlNode
    try:
        feed = topicFeeds.mget(topic)
    except:
        feed = loadXml(SITE_PATH / topic / "feed.xml")
        topicFeeds[topic] = feed

proc feedItems(chann: XmlNode): seq[XmlNode] {.sideEffect.} =
    result = collect:
            for (n, node) in enumerate(chann.items):
                if node.tag == "item":
                    chann.delete(n)
                    node

proc updateFeed*(topic: string, newArts: seq[Article]) =
    let
        feed = topic.fetchFeed
        chann = feed.child("channel")
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

template updateFeed*(a: Article) = updateFeed(a.topic, @[a])
