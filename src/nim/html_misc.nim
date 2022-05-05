import os,
       nre,
       uri,
       strutils,
       nimpy

import
    cfg,
    types,
    utils,
    topics

proc getArticlePy*(topic: string, page: string | int, slug: string): PyObject =
    let
        tg = ut.topic_group(topic)
        pg = string(page)
    if topic.getState[0] != -1:
        let donearts = tg[$topicData.done]
        for pya in donearts[page]:
            if pya.pyget("slug") == slug:
                return pya
    else:
        return PyNone

proc getArticleContent*(topic, page, slug: auto): string =
    getArticlePy(topic, page, slug).pyget("content")

proc getArticle*(topic, page, slug: auto): Article =
    let py = getArticlePy(topic, page, slug)
    if not pyisnone(py):
        initArticle(py, parseInt(page))
    else:
        emptyArt

proc getArticlePath*(a: Article): string {.inline.} = "/" / $a.topic / $a.page / a.slug

proc getArticleUrl*(a: Article): string = $WEBSITE_URL / getArticlePath(a)

proc getAuthor*(a: Article): string {.inline.} =
    if a.author.isEmptyOrWhitespace:
        if a.url.isEmptyOrWhitespace: "Unknown"
        else: a.url.parseuri().hostname
    else: a.author

const baseUri = initUri()

proc pathLink*(path: string, code = "", rel = true, amp = false): string {.gcsafe.} =
    let (dir, name, _) = path.splitFile
    $(
        (if rel: baseUri else: WEBSITE_URL) /
        (if amp: "amp/" else: "") /
        code /
        dir /
        (name.replace(sre("(index|404)$"), ""))
        )
