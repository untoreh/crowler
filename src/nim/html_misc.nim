import os,
       nre,
       uri,
       strutils,
       nimpy,
       karax/[vdom, karaxdsl],
       sequtils # zip

import
    cfg,
    types,
    utils,
    topics,
    articles,
    search,
    shorturls

proc pathLink*(path: string, code = "", rel = true, amp = false): string {.gcsafe.} =
    let (dir, name, _) = path.splitFile
    $(
        (if rel: baseUri else: WEBSITE_URL) /
        (if amp: "amp/" else: "") /
        code /
        dir /
        (name.replace(sre("(index|404)$"), ""))
        )

proc buildImgUrl*(url: string; origin: string; cls = "image-link"): VNode =
    var srcsetstr, bsrc: string
    if url != "":
        # add `?` because chromium doesn't treat it as a string otherwise
        let burl = "?" & url.toBString(true)
        bsrc = $(WEBSITE_URL_IMG / IMG_SIZES[1] / burl)
        for (view, size) in zip(IMG_VIEWPORT, IMG_SIZES):
            srcsetstr.add "//" & $(WEBSITE_URL_IMG / size / burl)
            srcsetstr.add " " & view & ","
    buildHtml(a(class = cls, href = origin, target = "_blank", alt = "post image source")):
        # the `alt="image"` is used to display the material-icons placeholder
        img(class = "material-icons", src = bsrc, srcset = srcsetstr, alt = "image",
                loading = "lazy")

proc fromSearchResult*(topic: string, pslug: string): Article =
    ## Construct an article from a stored search result
    let
        s = pslug.split("/")
        page = s[0]
        slug = s[1]

    getArticle(topic, page, slug)

import sets
proc buildRelated*(a: Article): VNode =
    ## Get a list of related articles by querying search db with tags and title words
    # try a full tag (or title) search first, then try word by word
    var kws = a.tags
    kws.add(a.title)
    for tag in a.tags:
        kws.add strutils.split(tag)
    kws.add(strutils.split(a.title))

    result = newVNode(VNodeKind.ul)
    result.setAttr("class", "related-posts")
    var c = 0
    var related: HashSet[string]
    for kw in kws:
        if kw.len < 3:
            continue
        let sgs = query(a.topic, kw.toLower, limit = N_RELATED)
        for sg in sgs:
            let relart = a.topic.fromSearchResult(sg)
            if relart.slug in related or relart.slug == "":
                continue
            else:
                related.incl relart.slug
            let
                entry = newVNode(li)
                link = newVNode(VNodeKind.a)
                img = buildImgUrl(relart.imageUrl, relart.url, "related-img")
            link.setAttr("href", getArticleUrl(relart))
            link.value = relart.title
            link.add newVNode(VNodeKind.text)
            link[0].value = relart.title
            entry.add img
            entry.add link
            result.add entry
            c += 1
        if c >= cfg.N_RELATED:
            return
