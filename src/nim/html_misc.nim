import os

import
    cfg,
    types

proc getArticlePath*(a: Article): string {.inline.} = "/" / $a.topic / $a.page / a.slug
proc getArticleUrl*(a: Article): string = $WEBSITE_URL / getArticlePath(a)
