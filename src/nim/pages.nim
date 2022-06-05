import
    karax / [karaxdsl, vstyles],
    uri,
    sequtils,
    unicode,
    xmltree,
    random

import html_misc,
       translate,
       translate_lang,
       amp

const tplRep = @{"WEBSITE_DOMAIN": WEBSITE_DOMAIN}
const ppRep = @{"WEBSITE_URL": $WEBSITE_URL.combine(),
                 "WEBSITE_DOMAIN": WEBSITE_DOMAIN}

proc getSubDirs(path: string): seq[int] =
    var dirs = collect((for f in walkDirs(path / "*"):
        try: parseInt(lastPathPart(f)) except: -1))
    sort(dirs, Descending)
    dirs

proc countDirFiles(path: string): int =
    len(collect(for f in walkFiles(path / "*"): f))

proc ensureHome(topic: string, pagenum: int) =
    ## Make sure the homepage links to the last page directory
    let
        topic_path = SITE_PATH / topic
        # homepage default dir
        page_path = topic_path / $pagenum
        # homepage index file
        home_index = page_path / "index.html"
        # the homepage index file should like to root topic dir
        target_home_link = topic_path / "index.html"
    createDir(page_path)
    # make sure the symlink points correctly
    if symlinkExists(target_home_link):
        # we should serve something
        if not fileExists(home_index):
            writeFile(home_index, "")
        if not fileExists(target_home_link) or
           not sameFile(home_index, target_home_link):
            removeFile(target_home_link)
            createSymlink(home_index, target_home_link)
    else:
        createSymlink(home_index, target_home_link)

proc getSubdirNumber(topic: string, iter: int = -1): (int, bool) =
    let topic_path = SITE_PATH / topic
    var topdir: int
    if iter < 0:
        # we are only interested in the highest numbered directory
        let dirs = getSubDirs(topic_path)
        if len(dirs) == 0:
            ensureHome(topic, 0)
            return (0, true)
        topdir = dirs.high
    else:
        topdir = iter
    # NOTE: we don't consider how many articles are in a batch
    # so this is a soft limit
    if countDirFiles(topic_path / $topdir) < MAX_DIR_FILES:
        return (topdir, false)
    (topdir + 1, true)

proc getLastTopicDir*(topic: string): string =
    let dirs = getSubDirs(SITE_PATH / topic)
    return $max(1, dirs.high)


proc pageArticles*(topic: string; pagenum: string): seq[string] =
    let dir = SITE_PATH / topic / pagenum
    collect:
        for p in walkFiles(dir / "*.html"):
            if lastPathPart(p) != "index.html": p

proc pageArticles*(topic: string): seq[string] =
    pageArticles(topic, getLastTopicDir(topic))

proc pageArticles*(topic: string; pagenum: int): seq[string] =
    pageArticles(topic, $pagenum)

proc articleExcerpt(a: Article): string =
    let alen = len(a.content) - 1
    let maxlen = min(alen, ARTICLE_EXCERPT_SIZE)
    if maxlen == alen:
        return a.content
    else:
        let runesize = runeLenAt(a.content, maxlen)
        return a.content[0..maxlen+runesize] & "..."

proc articleEntry(a: Article): VNode =
    let relpath = getArticlePath(a)
    buildHtml(article(class = "entry")):
        h2(class = "entry-title", id = a.slug):
            a(href = relpath):
                text a.title
        tdiv(class = "entry-info"):
            span(class = "entry-author"):
                text a.getAuthor & ", "
            time(class = "entry-date", datetime = ($a.pubDate)):
                italic:
                    text format(a.pubDate, "dd/MMM")
        tdiv(class = "entry-tags"):
            for t in a.tags:
                span(class = "entry-tag-name"):
                    icon("tag")
                    text t
        buildImgUrl(a.imageUrl, origin = a.url)
        tdiv(class = "entry-content"):
            verbatim(articleExcerpt(a))
            a(class = "entry-more", href = relpath):
                text "[continue]"
        hr()

proc buildShortPosts*(arts: seq[Article], homepage = false): string =
    for a in arts:
        result.add $articleEntry(a)

template topicPage*(topic: string, pagenum: string, istop = false) {.dirty.} =
    ## Writes a single page (fetching its related articles, if its not a template) to storage
    let arts = getDoneArticles(topic, pagenum = pagenum.parseInt)
    let content = buildShortPosts(arts)
    # if the page is not finalized, it is the homepage
    let footer = pageFooter(topic, pagenum, home = istop)
    let pagetree = buildPage(title = "", # this is NOT a `title` tag
        content = content,
        slug = pagenum,
        pagefooter = footer,
        topic = topic)

{.push gcsafe.}
proc processPage*(lang, amp: string, tree: VNode, relpath = "index"): VNode =
    if lang in TLangsCodes:
        let
            filedir = SITE_PATH
            tpath = filedir / lang / relpath
        var fc = initFileContext(tree, filedir, relpath,
            (src: SLang.code, trg: lang), tpath)
        debug "page: translating page to {lang}"
        result = translateLang(fc)
    else:
        result = tree
    if amp != "":
        debug "page: amping"
        result = result.ampPage

proc pageFromTemplate*(tpl, lang, amp: string): string =
    var txt = readfile(ASSETS_PATH / "templates" / tpl & ".html")
    let (vars, title, desc) = case tpl:
        of "dmca": (tplRep, "DMCA", fmt"dmca compliance for {WEBSITE_DOMAIN}")
        of "tos": (tplRep, "Terms of Service", fmt"Terms of Service for {WEBSITE_DOMAIN}")
        of "privacy-policy": (ppRep, "Privacy Policy", fmt"Privacy Policy for {WEBSITE_DOMAIN}")
        else: (tplRep, tpl, "")
    txt = multiReplace(txt, vars)
    let slug = slugify(title)
    let p = buildPage(title = title, content = txt)
    return $processPage(title, tpl, p)

proc articleTree*(capts: auto): VNode =
    # every article is under a page number
    let py = getArticlePy(capts.topic, capts.page, capts.art)
    pyLock.acquire()
    if not pyisnone(py):
        pyLock.release()
        debug "article: building post"
        var a: Article
        withPyLock:
            a = initArticle(py, parseInt(capts.page))
        let post = buildPost(a)
        debug "article: processing"
        return processPage(capts.lang, capts.amp, post, relpath = capts.art)
    else:
        debug "article: could not fetch python article"
        pyLock.release()

proc articleHtml*(capts: auto): string {.gcsafe.} =
    let t = articleTree(capts)
    if not t.isnil:
        t.asHtml
    else: ""

proc buildHomePage*(lang, amp: string): (VNode, VNode) =
    syncTopics()
    var a = default(Article)
    var
        n_topics = len(topicsCache)
        content: string
        processed: HashSet[string]

    for _ in 0..<cfg.N_TOPICS:
        var topic: string
        withPyLock:
            topic = ut.get_random_topic().to(string)
        if topic in processed:
            continue
        else:
            processed.incl topic
        let arts = getLastArticles(topic)
        if len(arts) > 0:
            content.add $articleEntry(arts[^1])
        if len(processed) == n_topics:
            break
    let pagetree = buildPage(title = "",
                         content = content,
                         slug = "",
                         topic = "")
    (pagetree, processPage(lang, amp, pagetree))

proc buildSearchPage*(topic: string, kws: string, lang: string): string =
    ## Builds a search page with 10 entries
    debug "search: lang:{lang}, topic:{topic}, kws:{kws}"
    var content, keywords: string
    if kws != "":
        keywords = kws.decodeUrl.sanitize
        let pslugs = query(topic, keywords, lang)
        if pslugs.len == 0:
            let r = buildHtml(tdiv(class = "search-results")):
                text "No results found."
            content.add $r
        else:
            for pslug in pslugs:
                let ar = topic.fromSearchResult(pslug)
                if not ar.isEmpty:
                    content.add $articleEntry(ar)
            if content.len == 0:
                let r = buildHtml(tdiv(class = "search-results")):
                    text "No results found."
                content.add $r
    else:
        let r = buildHtml(tdiv(class = "search-results")):
            text "Search query is empty."
        content.add $r
    let
        footer = pageFooter(topic, "s", home = false)
    let fromcat = if topic != "": fmt" (from category: {topic})" else: ""
    let tree = buildPage(title = fmt"""Search results for: "{keywords}"{fromcat}""",
                         content = content,
                         slug = "/s/" & kws,
                         pagefooter = footer,
                         topic = topic)
    $processPage(lang, "", tree)

proc buildSuggestList*(topic, input: string, prefix = ""): string =
    let sgs = suggest(topic, input)
    let p = buildHtml(ul(class = "search-suggest")):
        for sug in sgs:
            li():
                a(href = ($(WEBSITE_URL / (if topic != "g": topic / "s" else: "s") / encodeUrl((if prefix != "": prefix &
                        " " else: "") & sug)))): # FIXME: should `sug` be encoded?
                    text sug
    if sgs.len > 0:
        p.find(VNodeKind.li).setAttr("class", "selected")
    return $p


{.pop gcsafe.}

# when isMainModule:
#     discard
#     let topic = "vps"
#     let page = buildHomePage("en", "")
    # page.writeHtml(SITE_PATH / "index.html")
    # initSonic()
    # let argt = getLastArticles(topic)
    # echo buildRelated(argt[0])
