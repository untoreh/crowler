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
    $(WEBSITE_URL / getArticlePath(a, topic))
proc getArticleUrl*(a: PyObject, topic: string, lang: string): string {.inline.} =
    $(WEBSITE_URL / lang / getArticlePath(a, topic))

proc getArticlePath*(a: Article): string {.inline.} = $(baseUri / $a.topic / $a.page / a.slug)
proc getArticleUrl*(a: Article): string = $(WEBSITE_URL / getArticlePath(a))
proc getArticleUrl*(a: Article, lang: string): string {.inline.} = $(WEBSITE_URL / lang /
        getArticlePath(a))

proc isValidArticlePy*(py: PyObject): bool = ut.is_valid_article(py).to(bool)

proc getArticles*(topic: string, n = 3, pagenum: int = -1): Future[(int, seq[Article])] {.async.} =
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

proc getDoneArticles*(topic: string, pagenum: int, rev=true): Future[seq[Article]] {.async.} =
    withPyLock:
        let
            grp = site[].topic_group(topic)
            arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

        if arts.isnil or pyisnone(arts):
            result = @[]
        else:
            info "Fetching {arts.shape[0]} published articles for {topic}/{pagenum}"
            template addArt(iter) =
              for data in iter:
                if data.isValidArticlePy: # blacklisted articles are set to None
                  result.add(initArticle(data, pagenum))
            if rev:
              addArt(pybi[].reversed(arts))
            else:
              addArt(arts)


proc getLastArticles*(topic: string, n = 1): Future[seq[Article]] {.async.} =
  ## Return the latest articles, from newest to oldest (index 0 is newest)
  if await topic.isEmptyTopic:
    return
  var pagenum = await lastPageNum(topic)
  while pagenum >= 0:
    let arts = await getDoneArticles(topic, pagenum, rev=false)
    var a = arts.len - 1
    while a >= 0:
      result.add arts[a]
      if result.len >= n:
        return
      a.dec
    pagenum.dec

proc getArticlePy*(topic: string, page: string | int, slug: string): Future[PyObject] {.async.} =

    var pg: string
    when not (page is string):
      pg = page

    if (await topic.getState)[0] != -1:
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
        return emptyArt
    withPyLock:
        result = if not pyisnone(py):
            initArticle(py, parseInt(page))
        else:
            emptyArt


proc isEmpty*(a: Article): bool = a.isnil or a.title == "" or a.content == ""

proc getAuthor*(a: Article): string {.inline.} =
    if a.author.isEmptyOrWhitespace:
        if a.url.isEmptyOrWhitespace: "Unknown"
        else: a.url.parseuri().hostname
    else: a.author

proc deleteArt*(capts: UriCaptures, cacheOnly=false) {.async, gcsafe.} =
    let
        artPath = getArticlePath(capts)
        fpath = SITE_PATH / artPath
    !! (capts.topic != "")
    !! (capts.art != "")
    !! (capts.page != "")
    pageCache[].del(fpath)
    pageCache[].del(SITE_PATH / "amp" / artPath)
    # remove statistics about article
    statsDB.del(capts)
    for lang in TLangsCodes:
        pageCache[].del(SITE_PATH / "amp" / lang / artPath)
        pageCache[].del(SITE_PATH / lang / artPath)
    if not cacheOnly:
        let tg = (await topicsCache.fetch(capts.topic)).group[]
        await pygil.acquire()
        defer:
          if pygil.locked:
            pygil.release()
        let pageArts = tg[$topicData.done][capts.page]
        let pyslug = capts.art.nimValueToPy().newPyObject
        var toRemove: seq[int]
        for (n, a) in enumerate(pageArts):
            if (not pyisnone(a)) and a["slug"] == pyslug:
                toRemove.add n
                break
        for n in toRemove:
            pageArts[n] = PyNone

when isMainModule:
  echo waitFor getLastArticles("mini", 3)
