import
  xmltree,
  karax/vdom,
  uri,
  std/xmlparser,
  lists,
  strformat,
  chronos,
  chronos/asyncsync

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

threadVars((feed, rss, chann, channTitle, channLink, channDesc, XmlNode), (feedLock, AsyncLock))

var topicFeeds* {.threadvar.}: LockLruCache[string, Feed]

proc newFeed(): Feed = newElement("xml")

proc initFeed*() {.gcsafe.} =
  feedLock = newAsyncLock()
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

proc getTopicFeed*(topic: string, title: string, description: string, arts: seq[
    Article]): Feed =
  chann.clearChannel()
  channTitle[0].text = title.escape
  channLink[0].text = ($(config.websiteUrl / topic)).escape
  channDesc[0].text = description.escape
  for ar in arts:
    chann.add articleItem(ar)
  deepCopy(feed)

proc feedLink*(title, path: string): VNode {.gcsafe.} =
  result = newVNode(VNodeKind.link)
  result.setAttr("rel", "alternate")
  result.setAttr("title", title)
  result.setAttr("href", $(config.websiteUrl / path))

proc feedKey*(topic: string): string = topic & "-feed.xml"

proc update*(tfeed: Feed, topic: string, newArts: seq[Article],
    dowrite = false) =
  ## Load existing feed for given topic and update the feed (in-memory)
  ## with the new articles provided, it does not write to storage.
  checkNil tfeed
  let
    chann = tfeed.findel("channel")
    itms = chann.drainChannel
    arl = itms.len
    narl = newArts.len

  debug "rss: newArts: {narl}, previous: {arl}"
  let
    fill = RSS_N_ITEMS - arl
    rem = max(0, narl - fill)
    shrinked =
      if (rem > 0 and arl > 0):
        itms[0..<(max(0, arl-rem))]
      else: itms
  debug "rss: articles tail len {len(shrinked)}, newarts: {len(newArts)}"
  assert shrinked.len + narl <= RSS_N_ITEMS, fmt"shrinked: {shrinked.len}, newarticles: {narl}"
  for a in newArts:
    chann.add articleItem(a)
  for itm in shrinked:
    chann.add itm
  if dowrite:
    debug "rss: writing feed for topic: {topic}"
    pageCache[topic.feedKey] = tfeed.toXmlString

template updateFeed*(a: Article) =
  if a.title != "":
    feed.update(a.topic, @[a])

proc fetchFeedString*(topic: string): Future[string] {.async.} =
  return pageCache.lgetOrPut(topic.feedKey):
    await feedLock.acquire
    defer: feedLock.release
    let
      topPage = await topic.lastPageNum
      prevPage = max(0, topPage - 1)
    var
      arts = await getDoneArticles(topic, prevPage)
      tfeed = getTopicFeed(topic, topic, (await topicDesc(topic)), arts)
    if topPage > prevPage:
      arts = await getLastArticles(topic)
      tfeed.update(topic, arts, dowrite = false)
    topicFeeds[topic] = tfeed
    tfeed.toXmlString

proc fetchFeed*(topic: string): Future[Feed] {.async.} =
  try:
    result = topicFeeds[topic]
  except KeyError:
    let feedStr = await fetchFeedString(topic)
    try:
      result = topicFeeds[topic]
    except KeyError:
      result = topicFeeds.put(topic, parseXml(feedStr))

proc fetchFeedString*(): Future[string] {.async.} =
  return pageCache.lgetOrPut(config.websiteTitle.feedKey):
    let pytopics = await loadTopics(cfg.MENU_TOPICS)
    var
      arts: seq[Article]
      fetched = initTable[string, (seq[Article], int, int)](pytopics.len)
      topic = ""
    withPyLock:
      while arts.len < cfg.HOME_ARTS:
        for topicTuple in pytopics:
          topic = topicTuple[0].to(string) # topicTuple holds topic name and description etc..
          if topic notin fetched:
            fetched[topic] = default((seq[Article], int, int))
          withOutPyLock:
            let fec = fetched[topic].addr
            if fec[][0].len == 0:
              let (tArts, pagenum) =
                await getArticlesFrom(topic, n = 3, pagenum = fec[][1],
                    skip = fec[][2])
              fec[][0].add tArts
              fec[][1] = pagenum
            if fec[][0].len > 0:
              arts.add fec[][0].pop()
              fec[][2].inc
    await feedLock.acquire
    defer: feedLock.release
    let sfeed = getTopicFeed("", config.websiteTitle, config.websiteDescription, arts)
    topicFeeds[config.websiteTitle] = sfeed
    sfeed.toXmlString

proc fetchFeed*(): Future[Feed] {.async.} =
  try:
    result = topicFeeds[config.websiteTitle]
  except:
    let feedStr = await fetchFeedString()
    result = try:
      topicFeeds[config.websiteTitle]
    except KeyError:
      topicFeeds.put(config.websiteTitle, parseXml(feedStr))

proc clearFeed*() = pageCache.delete(config.websiteTitle.feedKey)
proc clearFeed*(topic: string) = pageCache.delete(topic.feedKey)

# when isMainModule:
#     initTopics()
#     let topic = "dedi"
#     pageCache[].del(topic)
#     pageCache[].del(config.websiteTitle)
