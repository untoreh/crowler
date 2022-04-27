import os,
       nre,
       uri,
       strutils

import
    cfg,
    types,
    utils

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

proc topicDesc*(topic: string): string = ""

