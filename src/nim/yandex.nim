import
       karax / [vdom],
       xmltree,
       lrucache,
       hashes,
       strtabs

import cfg,
       types,
       utils,
       ldj

const skipNodes = [VNodeKind.iframe, audio, canvas, embed, video, img, button, form, VNodeKind.head, svg]
const skipNodesXml = ["iframe", "audio", "canvas", "embed", "video", "img", "button", "form",
        "head", "svg", "document"]

var vbtmcache {.threadvar.}: LruCache[array[5, byte], XmlNode]
vbtmcache = newLruCache[array[5, byte], XmlNode](32)

let
    rootDir = SITE_PATH
    mainDoc = newVNode(VNodeKind.html)
    mainHeader = newVNode(VNodeKind.header)
    mainHeading = newVNode(VNodeKind.text)
    mainSubHeading = newVNode(VNodeKind.text)
    mainFigure = newVNode(VNodeKind.figure)
    mainImage = newVNode(VNodeKind.image)
    mainMenu = newVNode(VNodeKind.menu)
    crumbsHtml = newVNode(VNodeKind.tdiv)
    crumbsLinks = newSeq[(string, string)]()
    aTag = newVNode(VNodeKind.a)
    h1Node = newVNode(VNodeKind.h1)
    h2Node = newVNode(VNodeKind.h2)

var
    pageUrl, pageId, pageDescr, pageLang, pageRelated: string
    pageKws: seq[string]

proc fillHeader() =
    mainHeader.clear()
    h1Node.add mainHeading
    mainHeader.add h1Node

    h2Node.add mainSubHeading
    mainHeader.add h2Node

    mainFigure.add mainImage
    mainHeader.add mainFigure

    crumbsHtml.setAttr "data-block", "breadcrumblist"
    mainHeader.add mainMenu
    mainHeader.add crumbsHtml

proc setHeader(title, subtitle, imgUrl: string, menuLinks: seq[string] = @[]) =
    mainHeading.text = title
    mainSubHeading.text = subtitle
    mainImage.setAttr "src", imgUrl
    assert (aTag.lenAttr == 0) and (aTag.len == 0)
    mainMenu.clearChildren
    for link in menuLinks:
        let al = deepCopy(aTag)
        al.setAttr("src", link)
        mainMenu.add al
    crumbsHtml.clearChildren
    for (_, link) in crumbsLinks:
        let al = deepCopy(aTag)
        al.setAttr("src", link)
        crumbsHtml.add al

proc setHeader(ar: Article) = setHeader(ar.title, ar.desc, ar.imageUrl)

proc isScriptId(el: VNode, kind: VNodeKind, id = ""): bool =
    el.kind == kind and el.getAttr("id") == id

proc isScriptId(el: VNode, id = ""): bool =
    el.getAttr("id") == id

# proc processHead(inHead: VNode) =
#     var
#         canonicalUnset, titleUnset, crumbsUnset, dateUnset = true
#         title, subtitle, subUnset: string

#     crumbsLinks.setLen 0
#     pageKws.setLen 0
#     for el in inHead.preorder:
#         if el.kind in skipNodes:
#             continue
#         if titleUnset and el.kind == VNodeKind.title:
#             title = el.text
#             titleUnset = false
#        elif canonicalUnset and (el.kind == VNodeKind.link) and el.isLink(canonical):
#            pageUrl = el.getAttr("href", "")
#            canonicalUnset = false
#        elif subUnset and el.kind == VNodeKind.meta and el.hasAttr("description"):
#            subtitle = el.getAttr("description")
#            subUnset = false
#        elif dateUnset and el.isScriptId("ldj-webpage"):
#            let data = jsonCache.get(el.text.hash.int)
#            pageDate = data["datePublished"]
#            dateUnset = false
#            pageId = data["mainEntityOfPage"]["@id"]
#            pageKws.add data["keywords"]
#        elif crumbsUnset and isScriptId("ldj-breadcrumbs"):
#            let data = jsonCache.get(el.text.hash.int)
#            for listEl in data["itemListElement"]:
#                crumbsLinks.add (listEl["name"], listEl["item"])
#               crumbsUnset = false
#        titleUnset or subUnset or crumbsUnset or break
#     setHeader(title, subtitle,
#               imgUrl=getPageImage(pageId),
#               getPageLinks(pageId))



let feedNode = newElement("xml")
feedNode.attrs = {"version": "1.0", "encoding": "UTF-8"}.toXmlAttributes
let rssNode = newElement("rss")
rssNode.attrs = {"xmlns:yandex": "http://news.yandex.ru",
                  "xmlns:media": "http://search.yahoo.com/mrss/",
                  "xmlns:turbo": "http://turbo.yandex.ru",
                  "version": "2.0"}.toXmlAttributes 
let
    channelNode = newElement("channel")
    rssTitle = newElement("title")
    rssLink = newElement("link")
    rssDescription = newElement("description")
    rssLanguage = newElement("language")
    # rssAnalytics = newXmlNode("turbo:analytics")
    # rssAdNetwork = newXmlNode("turbo:adNetwork")

proc setChannelNode() =
    channelNode.clear()
    channelNode.add rssTitle
    channelNode.add rssLink
    channelNode.add rssDescription
    channelNode.add rssLanguage

rssNode.add channelNode

proc setFeed(topic, link, descr, lang: string = SLang.code): XmlNode =
    channelNode.clear()
    rssTitle.text = topic
    rssLink.text = link
    rssDescription.text = descr
    rssLanguage.text = lang

proc feedTopic(): string = rssTitle.text

let breadCrumbsList = newElement("breadcrumblist")
proc breadcrumbsTags() =
    breadCrumbsList.clear()
    for (name, link) in crumbsLinks:
        let bc = newElement("breadcrumb")
        var at = newStringTable()
        at["url"] = link
        at["text"] = name
        bc.attrs = at
        breadCrumbsList.add bc

let turboItemNode = newElement("item")
turboItemNode.attrs = {"turbo": "true"}.toXmlAttributes
# Page Information
let turboXHtml = newElement("turbo:extendedHtml")
turboXHtml.add newText("true")
turboItemNode.add turboXHtml
let turboLink = newElement("link")
turboLink.add newText("")
turboItemNode.add turboLink

let turboLang = newElement("language")
turboLang.add newText("")
turboItemNode.add turboLang

let turboSource = newElement("turbo:source")
turboSource.add newText("")
turboItemNode.add turboSource

let turboTopic = newElement("turbo:topic")
turboTopic.add newText("")
turboItemNode.add turboTopic

let turboDate = newElement("pubDate")
turboDate.add newText("")
turboItemNode.add turboDate

let turboAuthor = newElement("author")
turboAuthor.add newText("")
turboItemNode.add turboAuthor

let turboMetrics = newElement("metrics")
let turboYandex = newElement("yandex")
turboMetrics.add turboYandex
turboYandex.attrs = {"schema_identifier": ""}.toXmlAttributes
turboYandex.add breadCrumbsList

let turboRelated = newElement("yandex:related")
turboItemNode.add turboRelated

let turboContent = newElement("turbo:content")
turboContent.add newCData("")
turboItemNode.add turboContent

proc turboItem*(tree: VNode, ar: Article = static(Article())) =
    let
        itemHead = tree.find(VNodeKind.head)
        itemBody = tree.find(VNodeKind.body)

    turboItemNode.clear()
    pageLang = tree.getAttr("lang")
    if pageLang == "":
        pageLang = DEFAULT_LANG_CODE

    # processHead(itemHead)
    turboLink.text = pageUrl
    turboLang.text = pageLang
    turboSource.text = ar.url
    turboTopic.text = ar.topic
    turboDate.text = $ar.pubDate
    turboAuthor.text = ar.author
    breadcrumbsTags()
    # FIXME: we currently don't produce any related items
    turboRelated.text = pageRelated
    turboContent[0].text = "$itemHead$itemBody"
    channelNode.add newVerbatimText($turboItemNode)
