import nimpy
import cfg
import os
import sugar
import html
import times
import types
import strutils
import timeit
import strformat
import algorithm
import minhash {.all.}
import marshal
import karax / vdom
import std / importutils
import tables

let machinery = pyImport("importlib.machinery")
privateAccess(LocalitySensitive)

include "pages"

proc relimport(relpath: string): PyObject =
    let abspath = os.expandFilename(relpath & ".py")
    let loader = machinery.SourceFileLoader("config", abspath)
    return loader.load_module("config")

# we have to load the config before utils, otherwise the module is "partially initialized"
let pycfg = relimport("../py/config")
let ut = relimport("../py/utils")
const emptyseq: seq[string] = @[]

proc msgArticles(m: int): string =
    if m != 0:
        "getting $# articles from $# available ones for topic $#."
    else:
        "No articles were found for topic $#."

proc getarticles*(topic: string, n = 3, doresize = false, k = topicData.articles): seq[Article] =
    let grp = ut.zarr_topic_group(topic)
    var a: Article
    let arts = grp[$k]
    assert pyiszarray(arts)
    var data: PyObject
    let curtime = getTime()
    var parsed: seq[Article]
    var done: seq[PyObject]
    let h = arts.shape[0].to(int)
    let m = min(n, h)
    logger.log(lvlInfo, msgArticles(m) % [$m, $h, topic])
    for i in h-m..h-1:
        data = arts[i]
        a = new(Article)
        a.title = pyget(data, "title")
        a.desc = pyget(data, "desc")
        a.content = pyget(data, "content")
        a.author = pyget(data, "author")
        a.pubDate = pydate(data.get("pubDate"), curtime)
        a.imageUrl = pyget(data, "imageUrl")
        a.icon = pyget(data, "icon")
        a.url = pyget(data, "url")
        a.slug = pyget(data, "slug")
        a.lang = pyget(data, "lang")
        a.topic = pyget(data, "topic")
        a.tags = pyget(data, "tags", emptyseq)
        parsed.add(a)
        done.add(data)
    if k == topicData.articles and doresize:
        discard ut.save_topic(topic, done)
    return parsed


proc ensureDir(dir: string) =
    if not dirExists(dir):
        if fileExists(dir):
            logger.log(lvlinfo, "Deleting file that should be a directory " & dir)
            removeFile(dir)
        logger.log(lvlInfo, "Creating directory " & dir)
        createDir(dir)


proc initLS(): LocalitySensitive[uint64] =
    let hasher = initMinHasher[uint64](64)
    # very small band width => always find duplicates
    var lsh = initLocalitySensitive[uint64](hasher, 16)
    return lsh

proc getLSPath(topic: string): string =
    DATA_PATH / "topics" / topic / "lsh"

proc saveLS(topic: string, lsh: LocalitySensitive[uint64]) =
    let path = getLSPath(topic)
    createDir(path)
    writeFile(path / "lsh.json", $$lsh)

proc loadLS(topic: string): LocalitySensitive[uint64] =
    let lspath = getLSPath(topic) / "lsh.json"
    if fileExists(lspath):
        var lsh = to[LocalitySensitive[uint64]](readFile(lspath))
        # reinitialize minhasher since it is a cbinding func
        lsh.hasher = initMinHasher[uint64](64)
        return lsh
    else:
        initLS()


proc addArticle(lsh: LocalitySensitive[uint64], a: Article): bool =
    if not isDuplicate(lsh, a.content):
        lsh.add(a.content, $(len(lsh.fingerprints) + 1))
        return true
    false




proc pubPageFromTemplate(tpl: string, title: string, vars: seq[(string, string)] = tplRep) =
    var txt = readfile(ASSETS_PATH / "templates" / tpl)
    txt = multiReplace(txt, vars)
    let slug = slugify(title)
    let p = buildPage(title = title, content = txt)
    writeHtml(SITE_PATH, slug, p)

proc pubInfoPages() =
    ## Build DMCA, TOS, and GPDR pages
    pubPageFromTemplate("dmca.html", "DMCA")
    pubPageFromTemplate("tos.html", "Terms of Service")
    pubPageFromTemplate("privacy-policy.html", "Privacy Policy", ppRep)


proc pubPage(topic: string, pagenum: string, pagecount: int, ishome=false, finalize=false) =
    let arts = getarticles(topic, n = pagecount, k = topicData.done, doresize = false)
    let content = buildShortPosts(arts)
    writeHTML(SITE_PATH / topic,
                slug=(if ishome: "index"
                      else: pagenum / "index"),
                content)
    # if we pass a pagecount we mean to finalize
    if finalize:
        discard ut.update_page_size(topic, pagenum.parseInt, pagecount, final=true)

proc pubArchivePages(topic: string, pn: int, newpage: bool, pagecount: var int) =
    ## Always update both the homepage and the previous page
    let pages = ut.zarr_topic_group(topic)["pages"]
    var pagenum = pn.intToStr
    # current articles count
    let pn = pagenum.parseInt
    pubPage(topic, pagenum, pagecount)
    # Also build the previous page if we switched page
    if newpage:
        # make sure the second previous page is finalized
        let pn = pagenum.parseInt
        if pn > 1:
            let pagesize = pages[pn-2]
            pagecount = pagesize[0].to(int)
            let final = pagesize[1].to(bool)
            if not final:
                pagenum = (pn-2).intToStr
                pubPage(topic, pagenum, pagecount, finalize=true)
        # now update the just previous page
        pagecount = pages[pn-1][0].to(int)
        pagenum = (pn-1).intToStr
        pubPage(topic, pagenum, pagecount, finalize=true)



proc publish(topic: string, num: int = 0) =
    ##  Generates html for a list of `Article` objects and writes to file.
    let (pagenum, newpage) = getSubdirNumber(topic, num)
    var arts = getarticles(topic, doresize = true)
    let basedir = SITE_PATH / topic / $pagenum

    ensureDir(basedir)
    let lsh = loadLS(topic)
    var posts: seq[(VNode, string)]
    for a in arts:
        if addArticle(lsh, a):
            posts.add((buildPost(a), a.slug))
    # only write articles after having saved LSH
    # to avoid duplicates. It is fine to add articles to the set
    # even if we don't publish them, but we never want duplicates
    saveLS(topic, lsh)
    logger.log(lvlInfo, fmt"Writing {len(posts)} articles for topic: {topic}")
    for (tree, slug) in posts:
        writeHtml(basedir, slug, tree)

    let newposts = len(posts)
    # if its a new page, the page posts count is equivalent to the just published count
    var pagecount = (if newpage: newposts
                     else:  ut.get_page_size(topic, pagenum)[0].to(int) + newposts)
    discard ut.update_page_size(topic, pagenum, pagecount)

    pubArchivePages(topic, pagenum, newpage, pagecount)

when isMainModule:
    let topic = "vps"
    # ensureHome(topic)
    publish(topic)

    # var path = SITE_PATH / "index.html"
    # writeFile(path, &("<!doctype html>\n{buildPost()}"))
