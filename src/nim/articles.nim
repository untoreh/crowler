import uri,
       strutils,
       nimpy,
       os

import cfg,
       types,
       utils,
       server_types

proc getArticlePath*(capts: UriCaptures): string =
    capts.topic / capts.page / capts.art

proc getArticlePath*(a: PyObject, topic: string): string {.inline.} =
    topic / $a["page"] / ($a["slug"]).slugify
proc getArticleUrl*(a: PyObject, topic: string): string {.inline.} =
    $(WEBSITE_URL / getArticlePath(a, topic))
proc getArticleUrl*(a: PyObject, topic: string, lang: string): string {.inline.} =
    $(WEBSITE_URL / lang / getArticlePath(a, topic))

proc getArticlePath*(a: Article): string {.inline.} = $a.topic / $a.page / a.slug
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
    for data in arts:
        result.add(initArticle(data, pagenum))

proc getLastArticles*(topic: string): seq[Article] =
    let topPage = ut.get_top_page(topic).to(int)
    return getDoneArticles(topic, topPage)
