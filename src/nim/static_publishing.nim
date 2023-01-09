## Functions that should be used when building pages statically to update state

proc pubPage(topic: string, pagenum: string, nPagePosts: int, istop = false,
        with_arts = false) {.async.} =
  ## Writes a single page (fetching its related articles, if its not a template) to storage
  topicPage(topic, pagenum, istop)

  info "Updating page:{pagenum} for topic:{topic} with entries:{nPagePosts}"
  await processHTML(topic,
              pagenum / "index",
              pagetree)
  if with_arts:
    for a in arts:
      await processHtml(topic / pagenum, a.slug, (await buildPost(a)), a)

proc resetPages(topic: string) =
    ## Takes all the published articles in `done`
    ## and resets their page numbers
    let done = topicDonePages(topic)
    withPyLock:
        assert isa(done, site.za.Group)
        let topdir = len(done)
        if topdir == 0:
            return
        var i = 0
        var newdone = newSeq[PyObject]()
        for k in done.keys():
            let pagedone = done[k]
            newdone.add()

proc refreshPageSizes(topic: string) =
    withPyLock:
        let grp = site.topic_group(topic)
        let donearts = grp[$topicData.done]
        assert isa(donearts, site.za.Group)
        assert len(donearts) == len(grp[$topicData.pages])
        let topdir = len(donearts) - 1
        for pagenum in 0..<topdir:
            discard site.update_page_size(topic, pagenum, len(donearts[$pagenum]), final = true)
        discard site.update_page_size(topic, topdir, len(donearts[$topdir]), final = false)

proc pubAllPages(topic: string, clear = true) {.async.} =
  ## Starting from the homepage, rebuild all archive pages, and their articles
  let (topdir, numdone) = await topic.getState
  assert topdir == numdone, fmt"{topdir}, {numdone}"
  if clear:
    for d in walkDirs(SITE_PATH / topic / "*"):
      removeDir(d)
    let topic_path = SITE_PATH / topic
    for n in 0..topdir:
      ensureDir(topic_path / $n)
  block:
    let nPagePosts = await pageSize(topic, topdir)
    await pubPage(topic, $topdir, nPagePosts, finalize = false,
        with_arts = true, istop = true)
  for n in 0..<topdir:
    let pagenum = n
    var nPagePosts = await pageSize(topic, n)
    await pubPage(topic, $pagenum, nPagePosts, finalize = true,
        with_arts = true)
  ensureHome(topic, topdir)

proc resetTopic(topic: string) =
  syncPyLock():
    discard site.reset_topic_data(topic)
  pageCache.delete(topic.feedKey)
  clearSiteMap(topic, all = true)
  waitFor saveLS(topic, init(PublishedArticles))
