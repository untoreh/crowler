import nimpy,
       os,
       sugar,
       times,
       strutils,
       strformat,
       algorithm,
       marshal,
       karax / vdom,
       std / importutils,
       tables

import cfg,
       types,
       utils,
       html,
       rss,
       topics,
       articles,
       cache,
       search,
       pyutils,
       sitemap,
       lsh

let pageset = initLockTable[string, bool]()

include "pages"

proc ensureDir(dir: string) =
  if not dirExists(dir):
    if fileExists(dir):
      info "Deleting file that should be a directory {dir}"
      removeFile(dir)
    info "Creating directory {dir}"
    createDir(dir)

proc curPageNumber(topic: string): Future[int] {.async.} =
  withPyLock:
    return site[].get_top_page(topic).to(int)
  # return getSubdirNumber(topic, curdir)

proc pubPage(topic: string, pagenum: string, pagecount: int, finalize = false, istop = false,
        with_arts = false) {.async.} =
  ## Writes a single page (fetching its related articles, if its not a template) to storage
  topicPage(topic, pagenum, istop)

  info "Updating page:{pagenum} for topic:{topic} with entries:{pagecount}"
  await processHTML(topic,
              pagenum / "index",
              pagetree)
  # if we pass a pagecount we mean to finalize
  if finalize:
    withPyLock:
      discard site[].update_page_size(topic, pagenum.parseInt, pagecount, final = true)
  if with_arts:
    for a in arts:
      await processHtml(topic / pagenum, a.slug, (await buildPost(a)), a)

proc finalizePages(topic: string, pn: int, newpage: bool,
    pagecount: ptr int) {.async.} =
  ## Always update both the homepage and the previous page
  let pages = await topicPages(topic)
  var pagenum = pn.intToStr
  # current articles count
  let pnStr = pagenum
  let pn = pagenum.parseInt
  # the current page is the homepage
  await pubPage(topic, pnStr, pagecount[])
  # Also build the previous page if we switched page
  if newpage:
    # make sure the second previous page is finalized
    let pn = pagenum.parseInt
    if pn > 1:
      var pagesize: PyObject
      var final: bool
      withPyLock:
        pagesize = pages[pn-2]
        pagecount[] = pagesize[0].to(int)
        final = pagesize[1].to(bool)
      if not final:
        pagenum = (pn-2).intToStr
        await pubPage(topic, pagenum, pagecount[], finalize = true)
    # now update the just previous page
    withPyLock:
      pagecount[] = pages[pn-1][0].to(int)
    pagenum = (pn-1).intToStr
    await pubPage(topic, pagenum, pagecount[], finalize = true)

# proc resetPages(topic: string) =
#     ## Takes all the published articles in `done`
#     ## and resets their page numbers
#     let done = topicDonePages(topic)
#     withPyLock:
#         assert isa(done, site[].za.Group)
#         let topdir = len(done)
#         if topdir == 0:
#             return
#         var i = 0
#         var newdone = newSeq[PyObject]()
#         for k in done.keys():
#             let pagedone = done[k]
#             newdone.add()

proc filterDuplicates(topic: string, lsh: PublishedArticles, pagenum: int,
                      posts: ptr seq[(VNode, Article)],
                      donePy: ptr seq[PyObject],
                      doneArts: ptr seq[Article]): Future[bool] {.gcsafe, async.} =
  var (nProcessed, arts) = await getArticles(topic, pagenum = pagenum)
  let pubtime = getTime().toUnix
  if arts.len == 0:
    return false
  clear(pageset)
  for a in arts:
    if await addArticle(lsh, a.content):
      # make sure article titles/slugs are unique
      var u = 1
      var uslug = a.slug
      var utitle = a.title
      while uslug in pageset:
        uslug = fmt"{a.slug}-{u}"
        utitle = fmt"{a.title} ({u})"
        u += 1
      a.slug = uslug
      a.title = utitle
      a.page = pagenum
      if a.topic == "":
        a.topic = topic
        withPyLock:
          a.py["topic"] = topic
      posts[].add(((await buildPost(a)), a))
      withPyLock:
        a.py["slug"] = uslug
        a.py["title"] = utitle
        a.py["page"] = pagenum
        a.py["pubTime"] = pubtime
  # update done articles after uniqueness checks
  withPyLock:
    for (_, a) in posts[]:
      donePy[].add a.py
      doneArts[].add a
  await updateTopicPubdate()
  withPyLock:
    discard site[].save_done(topic, nProcessed, donePy[], pagenum)
  return true

proc pubTopic*(topic: string): Future[bool] {.gcsafe, async.} =
  ##  Generates html for a list of `Article` objects and writes to file.
  withPyLock:
    doassert topic in site[].load_topics()[1]
  info "pub: topic - {topic}"
  var pagenum = await curPageNumber(topic)
  let newpage = (await pageSize(topic, pagenum)) > cfg.MAX_DIR_FILES
  if newpage:
    pagenum += 1
  # The subdir (at $pagenum) at this point must be already present on storage
  let pagedir = topic / $pagenum

  let lsh = await loadLS(topic)
  let startTime = getTime()
  var
    posts: seq[(VNode, Article)]
    donePy: seq[PyObject]
    doneArts: seq[Article]
  while posts.len == 0 and (getTime() - startTime).inSeconds <
      cfg.PUBLISH_TIMEOUT:
    if not await filterDuplicates(topic, lsh, pagenum, posts.addr, donePy.addr,
        doneArts.addr):
      break

  # At this point articles "state" is updated on python side
  # new articles are "published" and the state (pagecache, rss, search) has to be synced
  when not cfg.SERVER_MODE:
    if newpage:
      ensureDir(SITE_PATH / pagedir)
  let newposts = len(posts)
  if newposts == 0:
    info "No new posts written for topic: {topic}"
    return false
  # only write articles after having saved LSH (within `filterDuplicates)
  # to avoid duplicates. It is fine to add articles to the set
  # even if we don't publish them, but we never want duplicates
  await saveLS(topic, lsh)
  info "Writing {newposts} articles for topic: {topic}"
  # FIXME: should this be here?
  for (tree, a) in posts:
    await processHtml(pagedir, a.slug, tree, a)
  # after writing the new page, ensure home points to the new page
  when not cfg.SERVER_MODE:
    if newpage:
      ensureHome(topic, pagenum)
  # if its a new page, the page posts count is equivalent to the just published count
  var pagecount: int
  pagecount = newposts
  withPyLock:
    if not newpage:
      # add previous published articles
      let pagesize = site[].get_page_size(topic, pagenum)
      # In case we didn't save the count, re-read from disk
      if not pyisnone(pagesize):
        pagecount += pagesize[0].to(int)
    discard site[].update_page_size(topic, pagenum, pagecount)

  await finalizePages(topic, pagenum, newpage, pagecount.addr)
  # update feed file
  when cfg.RSS:
    let tfeed = await topic.fetchFeed
    tfeed.update(topic, doneArts, dowrite = true)
  when cfg.SEARCH_ENABLED:
    for ar in doneArts:
      var relpath = topic / $pagenum / ar.slug
      await search.push(relpath)
  clearSiteMap(topic)
  clearSiteMap(topic, pagenum)
  # update ydx turbo items
  when cfg.YDX:
    writeFeed()
  info "pub: published {len(doneArts)} new posts."
  return true


let lastPubTime = create(Time)
let pubLock = create(AsyncLock)
pubLock[] = newAsyncLock()
lastPubTime[] = getTime()

proc pubTimeInterval(topic: string): Future[int] {.async.} =
  ## Publication interval is dependent on how many articles we can publish
  ## If we have 1000 arts: every 0.12 hours
  ## If we have 100 arts: every 1.2 hours
  ## If we have 10 arts: every 12 hours
  withPyLock:
    let artsLen = site[].load_articles(topic).len
    # in minutes
    result = 120.div(max(1, artsLen)) * 60


proc maybePublish*(topic: string) {.gcsafe, async.} =
  let t = getTime()
  if not pubLock[].locked:
    await pubLock[].acquire()
    defer: pubLock[].release
    let
      tpd = (await topicPubdate())
      pastTime = inMinutes(t - tpd)
    # Don't publish each topic more than `CRON_TOPIC_FREQ`
    if pastTime > (await pubTimeInterval(topic)):
      debug "pubtask: {topic} was published {pastTime} hours ago, publishing."
      lastPubTime[] = t
      discard await pubTopic(topic)
      # clear homepage and topic page cache
      deletePage("")
      deletePage("/" & topic)

proc resetTopic(topic: string) =
  syncPyLock():
    discard site[].reset_topic_data(topic)
  pageCache[].del(topic.feedKey)
  clearSiteMap(topic, all = true)
  waitFor saveLS(topic, initLS())

proc pubAllPages(topic: string, clear = true) {.async.} =
  ## Starting from the homepage, rebuild all archive pages, and their articles
  let (topdir, numdone) = await topic.getState
  assert topdir == numdone, fmt"{topdir}, {numdone}"
  when not cfg.SERVER_MODE:
    if clear:
      for d in walkDirs(SITE_PATH / topic / "*"):
        removeDir(d)
      let topic_path = SITE_PATH / topic
      for n in 0..topdir:
        ensureDir(topic_path / $n)
  block:
    let pagecount = await pageSize(topic, topdir)
    await pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true, istop = true)
  for n in 0..<topdir:
    let pagenum = n
    var pagecount = await pageSize(topic, n)
    await pubPage(topic, $pagenum, pagecount, finalize = true, with_arts = true)
  when not cfg.SERVER_MODE:
    ensureHome(topic, topdir)

# proc refreshPageSizes(topic: string) =
#     withPyLock:
#         let grp = site[].topic_group(topic)
#         let donearts = grp[$topicData.done]
#         assert isa(donearts, site[].za.Group)
#         assert len(donearts) == len(grp[$topicData.pages])
#         let topdir = len(donearts) - 1
#         for pagenum in 0..<topdir:
#             discard site[].update_page_size(topic, pagenum, len(donearts[$pagenum]), final = true)
#         discard site[].update_page_size(topic, topdir, len(donearts[$topdir]), final = false)

# import translate
# when isMainModule:
#     let topic = "vps"
#     # refreshPageSizes(topic)
#     # resetTopic("web")
#     # resetTopic("vps")
#     # resetTopic("dedi")
#     dopublish(topic)
#     quit()
#     let
#         topdir = 0
#         pagecount = pageSize(topic, topdir)
#     # pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true)
#     # pubPageFromTemplate("dmca.html", "DMCA")
