import tables,
       karax / [karaxdsl, vdom, vstyles],
       sequtils,
       strutils,
       strformat,
       os,
       std/with,
       std/httpclient,
       hashes,
       htmlparser,
       xmltree,
       nre,
       uri,
       lrucache,
       hashes

import cfg,
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
    pageUrl, pageDate, pageId, pageDescr, pageLang, pageSource, pageTopic, pageAuthor, pageRelated: string
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

proc isScriptId(el: VNode, kind: VNodeKind, id=""): bool =
    el.kind == kind and el.getAttr("id") == id

proc isScriptId(el: VNode, id=""): bool =
    el.getAttr("id") == id

proc processHead(inHead: VNode) =
    var
        canonicalUnset, titleUnset, crumbsUnset, dateUnset = true
        title, subtitle, subUnset: string

    crumbsLinks.setLen 0
    pageKws.setLen 0
    for el in inHead.preorder:
        if el.kind in skipNodes:
            continue
        if titleUnset and el.kind == VNodeKind.title:
            title = el.text
            titleUnset = false
       elif canonicalUnset and (el.kind == VNodeKind.link) and el.isLink(canonical):
           pageUrl = el.getAttr("href", "")
           canonicalUnset = false
       elif subUnset and el.kind == VNodeKind.meta and el.hasAttr("description"):
           subtitle = el.getAttr("description")
           subUnset = false
       elif dateUnset and el.isScriptId("ldj-webpage"):
           let data = jsonCache.get(el.text.hash.int)
           pageDate = data["datePublished"]
           dateUnset = false
           pageId = data["mainEntityOfPage"]["@id"]
           pageKws.add data["keywords"]
       elif crumbsUnset and isScriptId("ldj-breadcrumbs"):
           let data = jsonCache.get(el.text.hash.int)
           for listEl in data["itemListElement"]:
               crumbsLinks.add (listEl["name"], listEl["item"])
              crumbsUnset = false
       titleUnset or subUnset or crumbsUnset or break
    setHeader(title, subtitle,
              imgUrl=getPageImage(pageId),
              getPageLinks(pageId))

let breadCrumbsList = newXmlTree("breadcrumblist")
proc breadcrumbsTags()
    breadCrumbsList.clear()
	for (name, link) in crumbsLinks
        let bc = newXmlTree("breadcrumb")
        let at = newStringTable()
        at["url"] = link
        at["text"] = name
        bc.attrs  = at
        breadCrumbsList.add bc
    end
end

let turboItemNode = newXmlTree("item")
turboItemNode.setAttr "turbo" "true"
# Page Information
let turboXHtml = newXmlTree("turbo:extendedHtml")
turboXHtml.add newText("true")
turboItemNode.add turboXHtml
let turboLink = newXmlTree("link")
turboLink.add newText("")
turboItemNode.add turboLink

let turboLang = newXmlTree("language")
turboLang.add newText("")
turboItemNode.add turboLang

let turboSource = newXmlNode("turbo:source")
turboSource.add newText("")
turboItemNode.add turboSource

let turboTopic = newXmlNode("turbo:topic")
turboTopic.add newText("")
turboItemNode.add turboTopic

let turboDate = newXmlNode("pubDate")
turboDate.add newText(pageDate)
turboItemNode.add turboDate

let turboAuthor = newXmlNode("author")
turboAuthor.add newText("")
turboItemNode.add turboAuthor

let turboMetrics = newXmlNode("metrics")
let turboYandex = newXmlNode("yandex")
turboMetrics.add turboYandex
turboYandex.setAttr("schema_identifier", "")
turboYandex.add breadCrumbsList

let turboRelated = newXmlNode("yandex:related")
turboItemNode.add turboRelated

let turboContent = newXmlNode("turbo:content")
turboContent.add newCData("")
turboItemNode.add turboContent

proc turboItem(tree: VNode, autor= ""): XmlNode =
    let
        itemHead = tree.child(VNodeKind.head)
        itemBody = tree.child(VNodeKind.body)

    turboItemNode.clear()
    turboI
    let pageLang = tree.getAttr("lang")
    if pageLang == "":
        pageLang = DEFAULT_LANG_CODE

    processHead(itemHead)
    turboLink.text = pageUrl
    turboLang.text = pageLang
    turboSource.text = pageSource
    turboTopic.text = pageTopic
    turboDate.text = pageDate
    turboAuthor.text = pageAuthor
    breadcrumbsTags()
    turboRelated.text = pageRelated
    turboContent[0].text = "$itemHead$itemBody"
    return turboItemNode

let feedNode = newXmlFeed("xml")
feedNode.attrs = {"version": "1.0", "encoding": "UTF-8"}.toXmlAttributes
rssNode = newXmlNode("rss")
rssNode.attrs = {"xmlns:yandex": "http://news.yandex.ru",
                  "xmlns:media": "http://search.yahoo.com/mrss/",
                  "xmlns:turbo": "http://turbo.yandex.ru",
                  "version": "2.0"}
let
    channelNode = newXmlNode("channel")
    rssTitle = newXmlNode("title")
    rssLink = newXmlNode("link")
    rssDescription = newXmlNode("description")
    rssLanguage = newXmlNode("language")
    # rssAnalytics = newXmlNode("turbo:analytics")
    # rssAdNetwork = newXmlNode("turbo:adNetwork")

channelNode.add
rssNode.add channelNode

proc setFeed(title, link, descr, lang: string): XmlNode =
    rssTitle.text = title
    rssLink.text = link
    rssDescription.text = descr
    rssLanguage.text = lang
