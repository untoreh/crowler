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


proc getArticles*(topic: string, n = 3, pagenum: int = -1): Future[seq[Article]] {.async.} =
    let arts = await topicArticles(topic)
    withPyLock:
        !! pyiszarray(arts)
        var data: PyObject
        let
            total = arts.shape[0].to(int)
            count = min(n, total)
            start = total - count

        info "Fetching {count}(total:{total}) unpublished articles for {topic}/page:{pagenum}"
        for i in start..total - 1:
            # FIXME: some articles entries are _zeroed_ somehow
            data = arts[i]
            if pyisint(data):
                warn "articles: topic {topic} has _zeroed_ articles in storage."
                continue
            result.add(initArticle(data, pagenum))

proc getDoneArticles*(topic: string, pagenum: int): Future[seq[Article]] {.async.} =
    withPyLock:
        let
            grp = site[].topic_group(topic)
            arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

        if arts.isnil or pyisnone(arts):
            result = @[]
        else:
            info "Fetching {arts.shape[0]} published articles for {topic}/{pagenum}"
            for data in pybi[].reversed(arts):
                if not pyisnone(data): # blacklisted articles are set to None
                    result.add(initArticle(data, pagenum))

proc getLastArticles*(topic: string): Future[seq[Article]] {.async.} =
    return await getDoneArticles(topic, await lastPageNum(topic))

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

proc isEmpty*(a: Article): bool = a.isnil or a.title == ""

proc getAuthor*(a: Article): string {.inline.} =
    if a.author.isEmptyOrWhitespace:
        if a.url.isEmptyOrWhitespace: "Unknown"
        else: a.url.parseuri().hostname
    else: a.author

proc deleteArt*(capts: UriCaptures, cacheOnly=false) {.async, gcsafe.} =
    let
        artPath = getArticlePath(capts)
        fpath = SITE_PATH / artPath
    doassert capts.topic != ""
    doassert capts.art != ""
    doassert capts.page != ""
    pageCache[].del(fpath)
    pageCache[].del(SITE_PATH / "amp" / artPath)
    # remove statistics about article
    statsDB.del(capts)
    for lang in TLangsCodes:
        pageCache[].del(SITE_PATH / "amp" / lang / artPath)
        pageCache[].del(SITE_PATH / lang / artPath)
    if not cacheOnly:
        let tg = (await topicsCache.fetch(capts.topic)).group[]
        let pageArts = tg[$topicData.done][capts.page]
        let pyslug = capts.art.nimValueToPy().newPyObject
        var toRemove: seq[int]
        for (n, a) in enumerate(pageArts):
            if (not pyisnone(a)) and a["slug"] == pyslug:
                toRemove.add n
                break
        for n in toRemove:
            pageArts[n] = PyNone
