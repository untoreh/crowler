import cfg
import karax / [karaxdsl, vdom, vstyles]
import strutils
import os
import uri
import sugar
import sequtils
import types
import times
import html

const tplRep = @{"WEBSITE_DOMAIN": WEBSITE_DOMAIN}
const ppRep = @{"WEBSITE_URL": $WEBSITE_URL.combine(),
                 "WEBSITE_DOMAIN": WEBSITE_DOMAIN}
proc getSubDirs(path: string): seq[int] =
    var dirs = collect(for f in walkDirs(path / "*"):
                try: parseInt(lastPathPart(f)) except: -1)
    sort(dirs, Descending)
    dirs

proc countDirFiles(path: string): int =
    len(collect(for f in walkFiles(path / "*"): f))

proc getSubdirNumber(topic: string, iter: int): (int, bool) =
    let topic_path = SITE_PATH / topic
    if iter == 0:
        try:
            var dirs = getSubDirs(topic_path)
            var i = 0
            for d in dirs:
                i = d
                # NOTE: we don't consider how many articles are in a batch
                # so this is a soft limit
                if countDirFiles(topic_path / $d) < MAX_DIR_FILES:
                    return (d, false)
            return (i + 1, true)
        except ValueError:
            return (0, false)

proc getLastTopicDir*(topic: string): string =
    let dirs = getSubDirs(SITE_PATH / topic)
    return $max(1, dirs.high)

proc pageArticles*(topic: string; pagenum: string): seq[string] =
    let dir = SITE_PATH / topic / pagenum
    collect:
        for p in walkFiles(dir / "*.html"): p

proc pageArticles*(topic: string): seq[string] =
    pageArticles(topic, getLastTopicDir(topic))

proc pageArticles*(topic: string; pagenum: int): seq[string] =
    pageArticles(topic, $pagenum)

proc pageFooter(topic: string, pagenum: string, home: bool): VNode =
    let topic_path = SITE_PATH / topic
    buildHtml(tdiv(class = "post-footer")):
        nav(class = "page-crumbs")
        span(class = "prev-page"):
            a(href = (topic_path / pagenum)):
                text "Previous page"
        if not home:
            span(class = "next-page"):
                a(href = (topic_path / (parseInt(pagenum) + 1).intToStr)):
                    text "Next page"

proc buildShortPosts*(arts: seq[Article]): string =
    for a in arts:
        let p = buildHtml(article(class = "entry")):
            h2(id = "entry-title"):
                a(href = a.slug):
                    text a.title
            tdiv(class = "entry-info"):
                span(class = "entry-author"):
                    text a.author
                time(class = "entry-date", dadatetime = ($a.pubDate)):
                    italic:
                        text format(a.pubDate, "dd/MMM")
            buildImgUrl(a.imageUrl, "entry-image")
            tdiv(class = "entry-content"):
                verbatim(a.content[0..ARTICLE_EXCERPT_CHARS])
            tdiv(class = "entry-tags"):
                for t in a.tags:
                    span(class = "entry-tag-name"):
                        text t
        result.add(p)

proc ensureHome(topic: string) =
    ## Make sure the homepage links to the `0` page directory
    let
        topic_path = SITE_PATH / topic
        # homepage default dir
        home_path = topic_path / "0"
        # homepage index file
        home_index = home_path / "index.html"
        # the homepage index file should like to root topic dir
        target_home_link = topic_path / "index.html"
    createDir(home_path)
    # make sure the symlink points correctly
    if symlinkExists(target_home_link):
        if not fileExists(home_index):
            writeFile(home_index, "")
        if not fileExists(target_home_link) or
           not sameFile(home_index, target_home_link):
            removeFile(target_home_link)
            createSymlink(home_index, target_home_link)
    else:
        createSymlink(home_index, target_home_link)

# proc rebuildArchive()
