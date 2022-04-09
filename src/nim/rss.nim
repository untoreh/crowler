import
    xmltree,
    karax/vdom

import
    types,
    utils,
    html

type Feed = XmlNode

template `attrs=`(node: XmlNode, code: untyped) =
        node.attrs = code.toXmlAttributes

let feed = newElement("xml")
feed.attrs = {"version": "1.0", "encoding": "UTF-8"}
let rss = newElement("rss")
rss.setAttr("version", "2.0")
feed.add rss
let chann = newElement("channel")
let channTitle = newElement("title")
channTitle.text = ""
chann.add channTitle
let channLink = newElement("link")
channLink.text = ""
rss.add channLink
let channDesc = newElement("description")
channDesc.text = ""

proc getFeed(path: string, title: string, description: string, arts: seq[Article]): XmlNode =
    let topic = arts[0].topic
    channTitle.text = title
    channLink.text = WEBSITE_URL / path
    channDesc.text = description
    for ar in arts:
        let item = newElement("item")
        let itemTitle = newElement("title")
        itemTitle.text = ar.title
        item.add itemTitle
        let itemLink = newElement("link")
        itemLink.text = getArticleUrl(a)
        item.add itemLink
        let itemDesc = newElement("description")
        itemDesc.text = a.desc
        item.add itemDesc

template writeFeed*(path, args: untyped) =
    let f = getFeed(path, args)
    writeFile()

# <?xml version="1.0" encoding="UTF-8" ?>
# <rss version="2.0">

# <channel>
#   <title>W3Schools Home Page</title>
#   <link>https://www.w3schools.com</link>
#   <description>Free web building tutorials</description>
#   <item>
#     <title>RSS Tutorial</title>
#     <link>https://www.w3schools.com/xml/xml_rss.asp</link>
#     <description>New RSS tutorial on W3Schools</description>
#   </item>
#   <item>
#     <title>XML Tutorial</title>
#     <link>https://www.w3schools.com/xml</link>
#     <description>New XML tutorial on W3Schools</description>
#   </item>
# </channel>

# </rss>
