import uri,
       strutils,
       nimpy,
       os,
       algorithm

import cfg,
       types,
       utils,
       server_types,
       topics

proc getArticlePath*(capts: UriCaptures): string =
    $(baseUri / capts.topic / capts.page / capts.art)

proc getArticlePath*(a: PyObject, topic: string): string {.inline.} =
    $(baseUri / topic / $a["page"] / ($a["slug"]).slugify)
proc getArticleUrl*(a: PyObject, topic: string): string {.inline.} =
    $(WEBSITE_URL / getArticlePath(a, topic))
proc getArticleUrl*(a: PyObject, topic: string, lang: string): string {.inline.} =
    $(WEBSITE_URL / lang / getArticlePath(a, topic))

proc getArticlePath*(a: Article): string {.inline.} = $(baseUri / $a.topic / $a.page / a.slug)
proc getArticleUrl*(a: Article): string = $WEBSITE_URL / getArticlePath(a)
proc getArticleUrl*(a: Article, lang: string): string {.inline.} = $(WEBSITE_URL / lang / getArticlePath(a))


proc getArticles*(topic: string, n = 3, pagenum: int = -1): seq[Article] =
    let
        grp = ut.topic_group(topic)
        arts = grp[$topicData.articles]
    doassert pyiszarray(arts)
    var
        parsed: seq[Article]
        data: PyObject
    let
        total = arts.shape[0].to(int)
        count = min(n, total)
        start = total - count

    info "Fetching {count}(total:{total}) unpublished articles for {topic}/page:{pagenum}"
    for i in start..total - 1:
        data = arts[i]
        parsed.add(initArticle(data, pagenum))
    return parsed


proc getDoneArticles*(topic: string, pagenum: int): seq[Article] =
    let
        grp = ut.topic_group(topic)
        arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

    if pyisnone(arts):
        return @[]

    info "Fetching {arts.shape[0]} published articles for {topic}/{pagenum}"
    for data in pybi.reversed(arts):
        if not pyisnone(data): # blacklisted articles are set to None
            result.add(initArticle(data, pagenum))

proc getLastArticles*(topic: string): seq[Article] =
    let topPage = ut.get_top_page(topic).to(int)
    return getDoneArticles(topic, topPage)

proc getArticlePy*(topic: string, page: string | int, slug: string): PyObject =

    let
        tg = topicsCache.fetch(topic).group
        pg = string(page)

    if topic.getState[0] != -1:
        let donearts = tg[$topicData.done]
        for pya in donearts[page]:
            if (not pyisnone(pya)) and pya.pyget("slug") == slug:
                return pya
    else:
        return PyNone

proc getArticleContent*(topic, page, slug: string): string =
    getArticlePy(topic, page, slug).pyget("content")

proc getArticle*(topic, page, slug: auto): Article =
    let py = getArticlePy(topic, page, slug)
    if not pyisnone(py):
        initArticle(py, parseInt(page))
    else:
        emptyArt

proc getAuthor*(a: Article): string {.inline.} =
    if a.author.isEmptyOrWhitespace:
        if a.url.isEmptyOrWhitespace: "Unknown"
        else: a.url.parseuri().hostname
    else: a.author
