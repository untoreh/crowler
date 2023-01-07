import uri,
       strutils,
       os,
       std/enumerate,
       chronos,
       nimpy {.all.}

import cfg,
       types,
       utils,
       translate_types,
       server_types,
       topics,
       pyutils,
       cache,
       stats

proc getArticlePath*(capts: UriCaptures): string =
  $(baseUri / capts.topic / capts.page / capts.art)

proc getArticlePath*(a: PyObject, topic: string): string {.inline.} =
  $(baseUri / topic / $a["page"] / ($a["slug"]).slugify)
proc getArticleUrl*(a: PyObject, topic: string): string {.inline.} =
  $(config.websiteUrl / getArticlePath(a, topic))
proc getArticleUrl*(a: PyObject, topic: string,
    lang: string): string {.inline.} =
  $(config.websiteUrl / lang / getArticlePath(a, topic))

proc getArticlePath*(a: Article): string {.inline.} = $(baseUri / $a.topic /
    $a.page / a.slug)
proc getArticleUrl*(a: Article): string = $(config.websiteUrl / getArticlePath(a))
proc getArticleUrl*(a: Article, lang: string): string {.inline.} = $(config.websiteUrl / lang /
        getArticlePath(a))

proc isValidArticlePy*(py: PyObject): bool =
  {.locks: [pyGil].}:
    ut.is_valid_article(py).to(bool)

proc getArticles*(topic: string, n = 3, pagenum: int = -1): Future[(int, seq[
    Article])] {.async.} =
  let arts = await topicArticles(topic)
  withPyLock:
    !! pyiszarray(arts)
    var data: PyObject
    let total = arts.shape[0].to(int)

    info "Fetching {n}(total:{total}) unpublished articles for {topic}/page:{pagenum}"
    var invalidCount = 0
    for i in countDown(total - 1, 0):
      result[0] += 1
      data = arts[i]
      if not data.isValidArticlePy():
        invalidCount.inc
        continue
      result[1].add(initArticle(data, pagenum))
      if result[1].len >= n: # got the requested number of articles
        if invalidCount > 0:
          warn "articles: topic {topic} has {invalidCount} _empty_ articles in storage."
        break

proc getDoneArticles*(topic: string, pagenum: int, rev = true): Future[seq[
    Article]] {.async.} =
  withPyLock:
    let
      grp = site.topic_group(topic)
      arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

    if not arts.pyisnone:
      let n_arts = arts.shape[0]
      info "Fetching {n_arts} published articles for {topic}/{pagenum}"
      template addArt(iter) =
        for data in iter:
          if data.isValidArticlePy: # blacklisted articles are set to None
            result.add(initArticle(data, pagenum))
      addArt(if rev: pybi[].reversed(arts)
             else: arts)

proc allDoneContent*(topic: string): Future[seq[string]] {.async.} =
  ## Iterate over all published content of one topic.
  let lastPage = waitFor lastPageNum(topic)
  var grp: PyObject
  var arts: PyObject
  withPyLock:
    grp = site.topic_group(topic)
  for p in 0..<lastPage:
    var pageLen = 0
    withPyLock:
      arts = pyget(grp, $topicData.done / $p, PyNone)
      if not (arts.isnil or pyisnone(arts)):
        pageLen = arts.len
    if pageLen == 0:
      continue
    for n in 0..<pageLen:
      var content: string
      withPyLock:
        let data = arts[n]
        if data.isValidArticlePy:
          content = pyget(data, "content", "")
          if content.len > 0:
            result.add move content

proc isEmptyPage*(topic: string, pn: int, locked: static[bool]): Future[
    bool] {.async.} =
  let pg = await topicPage(topic, pn, locked)
  togglePyLock(locked):
    if pg.len == 0:
      result = true
    else:
      for a in pg:
        if a.isValidArticlePy:
          result = false
          break

proc nextPageNum*(topic: string, pn: int, last: int): Future[int] {.async.} =
  if pn < 0 or pn >= last:
    return pn
  var next = pn
  togglePyLock(true):
    let pages = await topicDonePages(topic, false)
    while next <= last:
      next.inc
      if not (await isEmptyPage(topic, next, false)):
        return next
    return pn

proc nextPageNum*(topic: string, pn: int): Future[int] {.async.} =
  let last = await lastPageNum(topic)
  return await nextPageNum(topic, pn, last)

proc prevPageNum*(topic: string, pn: int, last: int): Future[int] {.async.} =
  if pn <= 0 or pn > last:
    return last
  var prev = pn
  togglePyLock(true):
    let pages = await topicDonePages(topic, false)
    while prev >= 0:
      prev.dec
      if not (await isEmptyPage(topic, prev, false)):
        return prev
    return pn

proc prevPageNum*(topic: string, pn: int): Future[int] {.async.} =
  let last = await lastPageNum(topic)
  return await prevPageNum(topic, pn, last)

proc getArticlesFrom*(topic: string, n = 1, pagenum = -1, skip = 0): Future[(seq[Article], int)] {.async.} =
  ## Return the latest articles, from newest to oldest starting from page `pagenum` and going downward.
  ## `skip` controls how many articles to exclude from the head.
  if await topic.isEmptyTopicAsync:
    return
  var pagenum =
    if pagenum == -1: await lastPageNum(topic)
    else: pagenum
  var skip = skip
  while pagenum >= 0:
    let arts = await getDoneArticles(topic, pagenum, rev = false)
    var nArts = arts.len - 1
    while nArts >= 0:
      if skip > 0:
        skip.dec
        continue
      result[0].add arts[nArts]
      if result[0].len >= n:
        result[1] = pagenum
        return
      nArts.dec
    pagenum.dec
  result[1] = pagenum

proc getLastArticles*(topic: string, n = 1): Future[seq[Article]] {.async.} =
  ## Return the latest articles, from newest to oldest (index 0 is newest)
  return (await getArticlesFrom(topic, n))[0]

proc getArticlePy*(topic: string, page: string | int, slug: string): Future[
    PyObject] {.async.} =

  var pg: string
  when not (page is string):
    pg = page

  let st = await topic.getState
  if st[0] != -1:
    let donearts = await topicDonePages(topic)
    doassert not donearts.isnil
    withPyLock:
      if page in donearts:
        for pya in donearts[page]:
          if (not pyisnone(pya)) and pya.pyget("slug") == slug:
            return pya
      else:
        return PyNone
  else:
    return PyNone

proc getArticleContent*(topic, page, slug: string): Future[string] {.async.} =
  let art = await getArticlePy(topic, page, slug)
  withPyLock:
    return art.pyget("content")

proc getArticle*(topic, page, slug: auto): Future[Article] {.async.} =
  let py = await getArticlePy(topic, page, slug)
  if py.isnil:
    return emptyArt[]
  withPyLock:
    result = if not pyisnone(py):
            initArticle(py, parseInt(page))
        else:
            emptyArt[]


proc isEmpty*(a: Article): bool = a.isnil or a.title == "" or a.content == ""

proc getAuthor*(a: Article): string {.inline.} =
  if a.author.isEmptyOrWhitespace:
    if a.url.isEmptyOrWhitespace: "Unknown"
    else: a.url.parseuri().hostname
  else: a.author

proc deleteArt*(capts: UriCaptures, cacheOnly = false) {.async, gcsafe.} =
  !! (capts.topic != "")
  !! (capts.art != "")
  !! (capts.page != "")
  # Delete article cached pages
  deletePage(capts)
  # remove statistics about article
  statsDB.del(capts)
  if not cacheOnly:
    withPyLock:
      let
        ts = Topics.fetch(capts.topic)
        tg = ts.group
        pageArts = tg[$topicData.done][capts.page]
        pyslug = capts.art.nimValueToPy().newPyObject
      var toRemove: seq[int]
      for (n, a) in enumerate(pageArts):
        if (not pyisnone(a)) and a["slug"] == pyslug:
          toRemove.add n
          break
      for n in toRemove:
        pageArts[n] = PyNone

# when isMainModule:
#   discard
#   echo waitFor getLastArticles("mini", 3)
#   for cnt in allDoneContent("mini"):
#     continue
#   echo waitFor nextPageNum("mini", 2)
