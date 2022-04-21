import
    karax / [karaxdsl, vdom, vstyles],
    strutils,
    os,
    uri,
    sugar,
    sequtils,
    times,
    unicode,
    algorithm

import cfg,
       types,
       utils,
       html,
       html_misc,
       translate,
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

proc buildShortPosts*(arts: seq[Article], homepage=false): string =
    var relpath: string
    for a in arts:
        relpath = getArticlePath(a)
        let p = buildHtml(article(class = "entry")):
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
            buildImgUrl(a.imageUrl, "entry-image")
            tdiv(class = "entry-content"):
                verbatim(articleExcerpt(a))
                a(class = "entry-more", href = relpath):
                    text "[continue]"
            hr()
        result.add(p)

proc buildHomePage*(lang: string, amp: bool, tree: VNode): VNode {.gcsafe.} =
    if lang in TLangsCodes:
        # result = translateLang(tree)
        result = tree
    else:
        result = tree
    if amp:
        result = result.ampPage

proc buildHomePage*(lang: string, tree: VNode): VNode {.gcsafe.} =
    if lang in TLangsCodes:
        # result = translateLang(tree)
        result = tree
    else:
        result = tree

proc buildHomePage*(amp: bool, tree: VNode): VNode {.gcsafe.} =
    if amp:
        return ampPage(tree)
    else:
        return tree

proc buildHomePage*(lang: string, amp: bool): (VNode, VNode) {.gcsafe.} =
    var a = default(Article)
    a.content = "this is homepage"
    let tree = buildPage("Home Page", "")
    (tree, buildHomePage(lang, amp, tree))
