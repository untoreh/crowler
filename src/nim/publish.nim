import nimpy,
       os,
       sugar,
       strutils,
       strformat,
       algorithm,
       marshal,
       karax / vdom,
       std / importutils,
       tables,
       macros

import times except milliseconds

import cfg,
       types,
       utils,
       html,
       topics,
       articles,
       cache,
       search,
       pyutils,
       sitemap,
       lsh,
       sharedqueue

const SERVER_MODE* {.booldefine.} = false
when SERVER_MODE:
  import rss
  when cfg.YDX:
    import yandex

threadVars(
  (pageset, LockTable[string, bool]),
  (lastPubTime, Time),
  (pubLock, ThreadLock)
)

include "pages"

proc initPublish*() =
  initPages()
  lastPubTime = getTime()
  pageset = initLockTable[string, bool]()
  pubLock = newThreadLock()

proc ensureDir(dir: string) =
  if not dirExists(dir):
    if fileExists(dir):
      info "Deleting file that should be a directory {dir}"
      removeFile(dir)
    info "Creating directory {dir}"
    createDir(dir)

proc curPageNumber(topic: string): Future[int] {.async.} =
  withPyLock:
    return site.get_top_page(topic).to(int)
  # return getSubdirNumber(topic, curdir)
  #
macro infoPub(msg: static[string]) =
  var m = "pub({topic}): "
  m.add msg
  quote do:
    info `m`

proc finalizePage(topic: string, pagenum, postsCount: int) {.async.} =
  withPylock:
    discard site.update_page_size(topic, pagenum, postsCount, final = true)


proc finalizePages(topic: string, pn: int, newpage: bool,
                   postsCount: int, static_pub: static[
                       bool] = false) {.async.} =
  ## Always update both the homepage and the previous page
  # if its a new page, the page posts count is equivalent to the just published count
  var postsCount = postsCount
  infopub "updating db page size"
  withPyLock:
    if not newpage:
      # add previous published articles
      let pagesize = site.get_page_size(topic, pn)
      # In case we didn't save the count, re-read from disk
      if not pyisnone(pagesize):
        postsCount += pagesize[0].to(int)
    discard site.update_page_size(topic, pn, postsCount)

  let pages = await topicPages(topic)
  var pagenum = pn
  # # current articles count
  # let pn = pagenum
  # the current page is the homepage
  when static_pub: # static publishing is disabled
    await pubPage(topic, pn.intToStr, postsCount)
  # Also build the previous page if we switched page
  if newpage:
    # make sure the second previous page is finalized
    let pn = pagenum
    if pn > 1:
      var pagesize: PyObject
      var final: bool
      withPyLock:
        pagesize = pages[pn-2]
        postsCount = pagesize[0].to(int)
        final = pagesize[1].to(bool)
      if not final:
        pagenum = pn - 2
        await finalizePage(topic, pagenum, postsCount)
        when static_pub:
          await pubPage(topic, pagenum.intToStr, postsCount, finalize = true)
    # now update the just previous page
    withPyLock:
      postsCount = pages[pn-1][0].to(int)
    pagenum = pn - 1
    await finalizePage(topic, pagenum, postsCount)
    when static_pub:
      await pubPage(topic, pagenum.intToStr, postsCount, finalize = true)

template pySaveDone() =
  withPyLock:
    discard site.save_done(topic, nProcessed, donePy[], pagenum)

proc filterDuplicates(topic: string, lsh: PublishedArticles, pagenum: int,
                      posts: ptr seq[(VNode, Article)],
                      donePy: ptr seq[PyObject],
                      doneArts: ptr seq[Article],
                      ): Future[bool] {.gcsafe, async.} =

  var (nProcessed, arts) = await getArticles(topic, pagenum = pagenum)
  let pubtime = getTime().toUnix
  if arts.len == 0:
    pySaveDone()
    return false
  clear(pageset)
  for a in arts:
    if await addArticle(lsh, a.content.unsafeAddr):
      # make sure article titles/slugs are unique
      var
        u = 1
        uslug = a.slug
        utitle = a.title
      while uslug in pageset:
        uslug = fmt"{a.slug}-{u}"
        utitle = fmt"{a.title} ({u})"
        u += 1
      a.topic = topic
      a.slug = uslug
      a.title = utitle
      a.page = pagenum
      a.pubTime = pubtime.fromUnix
      withPyLock:
        a.py["topic"] = topic
        a.py["slug"] = uslug
        a.py["title"] = utitle
        a.py["page"] = pagenum
        a.py["pubTime"] = pubtime
      block:
        var post: VNode
        when STATIC_PUBLISHING:
          post = await buildPost(a)
        posts[].add((post, a))
  # update done articles after uniqueness checks
  withPyLock:
    for (_, a) in posts[]:
      donePy[].add a.py
      doneArts[].add a
  pySaveDone()
  return true

proc ensureLS(topic: string): Future[PublishedArticles] {.async, raises: [].} =
  try:
    result = await loadLS(topic)
  except:
    warn "Failed to load lsh for topic {topic}. Rebuilding..."
    result = init(PublishedArticles)
    try:
      let content = await allDoneContent(topic)
      for cnt in content:
        discard await addArticle(result, cnt.unsafeAddr)
    except:
      warn "Failed to rebuild lsh for topic {topic}. Proceeding anyway."

template stateUpdates() =
  if newpage:
    ensureDir(SITE_PATH / pagedir)
  # after writing the new page, ensure home points to the new page
  infopub "Writing {nNewPosts} articles for topic: {topic}"
  for (tree, a) in posts:
    await processHtml(pagedir, a.slug, tree, a)
  if newpage:
    ensureHome(topic, pagenum)
  # update feed file
  infopub "updating feeds"
  let tfeed = await topic.fetchFeed
  tfeed.update(topic, doneArts, dowrite = true)
  when cfg.SEARCH_ENABLED:
    infopub "indexing search"
    for ar in doneArts:
      var relpath = topic / $pagenum / ar.slug
      await search.push(relpath)
  infopub "clearing sitemaps"
  clearSiteMap(topic)
  clearSiteMap(topic, pagenum)
  # update ydx turbo items
  when cfg.YDX:
    infopub "updating yandex"
    writeFeed()


proc pubTopic*(topic: string): Future[
    bool] {.gcsafe, async.} =
  ##  Generates html for a list of `Article` objects and writes to file.
  infopub "start"
  withPyLock:
    doassert topic in site.callMethod("load_topics")[1]
  if not (await hasUnpublishedArticles(topic)):
    infopub "no unpublished articles"
    return false
  # Ensure there are some articles available to be published
  var pagenum = await curPageNumber(topic)
  let newpage = (await pageSize(topic, pagenum)) > cfg.MAX_DIR_FILES
  if newpage:
    pagenum += 1
  # The subdir (at $pagenum) at this point must be already present on storage
  let pagedir = topic / $pagenum

  infopub "lsh"
  let lsh = await ensureLS(topic)
  let startTime = getTime()
  var
    posts: seq[(VNode, Article)]
    donePy: seq[PyObject]
    doneArts: seq[Article]

  infopub "filter"
  while posts.len == 0 and
        (getTime() - startTime).inSeconds < PUBLISH_TIMEOUT:
    let filtered =
      await filterDuplicates(topic, lsh, pagenum, posts.addr, donePy.addr, doneArts.addr)
    if not filtered: # We ran out of articles
      break

  let nNewPosts = len(posts)
  if nNewPosts == 0:
    info "No new posts written for topic: {topic}"
    return false
  # only write articles after having saved LSH (within `filterDuplicates)
  # to avoid duplicates. It is fine to add articles to the set
  # even if we don't publish them, but we never want duplicates
  infopub "save lsh"
  await saveLS(topic, lsh)
  infopub "finalizing pages"
  await finalizePages(topic, pagenum, newpage, len(posts))
  # At this point articles "state" is updated on python side
  # new articles are "published" and the state (pagecache, rss, search) has to be synced
  when false: # It is disabled since we don't do static publishing and
    stateUpdates() # the server cache has a short TTL...so it will eventually update
  doassert await updateTopicPubdate(topic)
  infopub "published {nNewPosts} new posts."
  return true

proc pubTimeInterval(topic: string): Future[int] {.async.} =
  ## Publication interval is dependent on how many articles we can publish
  ## If we have 1000 arts: every 0.12 hours
  ## If we have 100 arts: every 1.2 hours
  ## If we have 10 arts: every 12 hours
  withPyLock:
    let artsLen = site.load_articles(topic).len
    # in minutes
    result = 120.div(max(1, artsLen)) * 60

proc maybePublish*(topic: string) {.gcsafe, async.} =
  let t = getTime()
  withLock(pubLock):
    let
      tpd = (await topicPubdate(topic))
      pastTime = inMinutes(t - tpd)
      pubInterval = await pubTimeInterval(topic)
    if pastTime > pubInterval:
      debug "pubtask: {topic} was published {pastTime} hours ago, publishing."
      lastPubTime = t
      let published = await pubTopic(topic)
      if published and SERVER_MODE:
        # clear homepage and topic page cache
        deletePage("")
        deletePage("/" & topic)
    else:
      let remaining = pubInterval - pastTime
      debug "pubtasks: time until next {topic} publishing: {remaining} minutes."
