import os,
       nre,
       uri,
       strutils,
       nimpy,
       karax/[vdom, karaxdsl],
       sets,
       chronos,
       sequtils # zip

import
    cfg,
    types,
    utils,
    topics,
    articles,
    search,
    shorturls

var
    facebookUrlStr: string
    twitterUrlStr: string
    facebookUrl*: ptr string
    twitterUrl*: ptr string

proc initSocial*() {.gcsafe.} =
    syncPyLock:
        {.cast(gcsafe).}:
            facebookUrlStr = site.fb_page_url.to(string)
            twitterUrlStr = site.twitter_url.to(string)
            facebookUrl = facebookUrlStr.unsafeAddr
            twitterUrl = twitterUrlStr.unsafeAddr

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

proc fromSearchResult*(pslug: string): Future[Article] {.async.} =
    ## Construct an article from a stored search result
    let
        s = pslug.split("/")
        topic = s[0]
        page = s[1]
        slug = s[2]

    debug "html: fromSearchResult - {pslug}"
    if topic != "" and topic in topicsCache:
        result = await getArticle(topic, page, slug)

proc buildRelated*(a: Article): Future[VNode] {.async.} =
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
        let sgs = await query(a.topic, kw.toLower, limit = N_RELATED)
        logall "html: suggestions {sgs}, from kw: {kw}"
        # if sgs.len == 1 and sgs[0] == "//":
        #     return
        for sg in sgs:
            let relart = await fromSearchResult(sg)
            if (relart.isnil or (relart.slug in related or relart.slug == "")):
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
