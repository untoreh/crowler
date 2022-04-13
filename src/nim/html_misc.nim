import os,
       nre

import
    cfg,
    types,
    utils

proc getArticlePath*(a: Article): string {.inline.} = "/" / $a.topic / $a.page / a.slug
proc getArticleUrl*(a: Article): string = $WEBSITE_URL / getArticlePath(a)

proc pathLink*(path: string, code = "", rel = true, amp = false): string =
    let name = lastPathPart(path)
    (case rel:
        of true: "/"
        else: $WEBSITE_URL) /
    (case amp:
        of true: "amp/"
        else: "") /
    (name.replace(sre("(index|404)$"), ""))

proc topicDesc*(topic: string): string = ""
