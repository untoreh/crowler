import uri,
       strutils,
       nimpy,
       os,
       algorithm

import cfg,
       types,
       utils,
       server_types,
       topics,
       pyutils

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
proc getArticleUrl*(a: Article, lang: string): string {.inline.} = $(WEBSITE_URL / lang /
        getArticlePath(a))


proc getArticles*(topic: string, n = 3, pagenum: int = -1): seq[Article] =
    let arts = topicArticles(topic)
    withPyLock:
        doassert pyiszarray(arts)
        var data: PyObject
        let
            total = arts.shape[0].to(int)
            count = min(n, total)
            start = total - count

        info "Fetching {count}(total:{total}) unpublished articles for {topic}/page:{pagenum}"
        for i in start..total - 1:
            data = arts[i]
            result.add(initArticle(data, pagenum))

proc getDoneArticles*(topic: string, pagenum: int): seq[Article] =
    withPyLock:
        let
            grp = ut.topic_group(topic)
            arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

        if arts.isnil or pyisnone(arts):
            result = @[]
        else:
            info "Fetching {arts.shape[0]} published articles for {topic}/{pagenum}"
            for data in pybi.reversed(arts):
                if not pyisnone(data): # blacklisted articles are set to None
                    result.add(initArticle(data, pagenum))

proc getLastArticles*(topic: string): seq[Article] =
    return getDoneArticles(topic, lastPageNum(topic))

proc getArticlePy*(topic: string, page: string | int, slug: string): PyObject =

    let pg = string(page)

    if topic.getState[0] != -1:
        let donearts = topicDonePages(topic)
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

proc getArticleContent*(topic, page, slug: string): string =
    let art = getArticlePy(topic, page, slug)
    withPyLock:
        return art.pyget("content")

proc getArticle*(topic, page, slug: auto): Article =
    var py {.threadvar.}:  PyObject
    py = getArticlePy(topic, page, slug)
    withPyLock:
        result = if not pyisnone(py):
            initArticle(py, parseInt(page))
        else:
            emptyArt

proc getAuthor*(a: Article): string {.inline.} =
    if a.author.isEmptyOrWhitespace:
        if a.url.isEmptyOrWhitespace: "Unknown"
        else: a.url.parseuri().hostname
    else: a.author
