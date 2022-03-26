import nimpy,
       os,
       sugar,
       html,
       times,
       strutils,
       timeit,
       strformat,
       algorithm,
       minhash {.all.},
       marshal,
       karax / vdom,
       std / importutils,
       tables

import cfg,
       types

privateAccess(LocalitySensitive)
var pageset = Table[string, bool]()

include "pages"


# we have to load the config before utils, otherwise the module is "partially initialized"
let pycfg = relpyImport("../py/config")
let ut* = relpyImport("../py/utils")

proc getArticles*(topic: string, n = 3, pagenum: int = -1): seq[Article] =
    let
        grp = ut.topic_group(topic)
        arts = grp[$topicData.articles]
    assert pyiszarray(arts)
    var
        parsed: seq[Article]
        data: PyObject
    let
        total = arts.shape[0].to(int)
        count = min(n, total)
        start = total - count

    logger.log(lvlInfo, fmt"Fetching {count}(total:{total}) unpublished articles for {topic}/page:{pagenum}")
    for i in start..total - 1:
        data = arts[i]
        parsed.add(initArticle(data, pagenum))
    return parsed

proc getDoneArticles*(topic: string, pagenum: int): seq[Article] =
    let
        grp = ut.topic_group(topic)
        arts = pyget(grp, $topicData.done / pagenum.intToStr, PyNone)

    if pyisnone(arts):
        return @[]

    logger.log(lvlInfo, fmt"Fetching {arts.shape[0]} published articles for {topic}/{pagenum}")
    for data in arts:
        result.add(initArticle(data, pagenum))



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

proc pageSize(topic: string, pagenum: int): int =
    let py = ut.get_page_size(topic, pagenum)
    if pyisnone(py):
        error fmt"Page number: {pagenum} not found for topic: {topic} ."
        return 0
    py[0].to(int)

proc curPageNumber(topic: string): int =
    return ut.get_top_page(topic).to(int)
    # return getSubdirNumber(topic, curdir)

proc pubPage(topic: string, pagenum: string, pagecount: int, finalize = false, with_arts = false) =
    let
        arts = getDoneArticles(topic, pagenum = pagenum.parseInt)
        content = buildShortPosts(arts)
        # if the page is not finalized, it is the homepage
        footer = pageFooter(topic, pagenum, not finalize)
        page = buildPage(content = content, pagefooter = footer)

    logger.log(lvlInfo, fmt"Updating page:{pagenum} for topic:{topic} with entries:{pagecount}")
    let topic_path = SITE_PATH / topic
    writeHTML(topic_path,
                slug = pagenum / "index",
                page)
    # if we pass a pagecount we mean to finalize
    if finalize:
        discard ut.update_page_size(topic, pagenum.parseInt, pagecount, final = true)
    if with_arts:
        for a in arts:
            writeHTML(topic_path / pagenum, a.slug, buildPost(a))

proc finalizePages(topic: string, pn: int, newpage: bool, pagecount: var int) =
    ## Always update both the homepage and the previous page
    let pages = ut.topic_group(topic)["pages"]
    var pagenum = pn.intToStr
    # current articles count
    let pn = pagenum.parseInt
    # the current page is the homepage
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
                pubPage(topic, pagenum, pagecount, finalize = true)
        # now update the just previous page
        pagecount = pages[pn-1][0].to(int)
        pagenum = (pn-1).intToStr
        pubPage(topic, pagenum, pagecount, finalize = true)

# proc resetPages(topic: string) =
#     ## Takes all the published articles in `done`
#     ## and resets their page numbers
#     let done = ut.topic_group(topic)[$topicData.done]
#     assert isa(done, ut.za.Group)
#     let topdir = len(done)
#     if topdir == 0:
#         return
#     var i = 0
#     var newdone = newSeq[PyObject]()
#     for k in done.keys()
#         let pagedone = done[k]
#         newdone.add()

proc publish(topic: string) =
    ##  Generates html for a list of `Article` objects and writes to file.
    var pagenum = curPageNumber(topic)
    let newpage = pageSize(topic, pagenum) > cfg.MAX_DIR_FILES
    if newpage:
        pagenum += 1
    # The subdir (at $pagenum) at this point must be already present on storage
    var arts = getArticles(topic, pagenum = pagenum)
    let basedir = SITE_PATH / topic / $pagenum

    let lsh = loadLS(topic)
    var posts: seq[(VNode, Article)]
    clear(pageset)
    for a in arts:
        if addArticle(lsh, a):
            # make sure article titles/slugs are unique
            var u = 1
            var uslug = a.slug
            var utitle = a.title
            while uslug in pageset:
                uslug = fmt"{a.slug}-{u}"
                utitle = fmt"{a.title} ({u})"
                u += 1
            a.py["slug"] = uslug
            a.slug = uslug
            a.py["title"] = utitle
            a.title = utitle
            posts.add((buildPost(a), a))
    # update done articles after uniqueness checks
    let done = collect(for (_, a) in posts: a.py)
    discard ut.save_done(topic, len(arts), done, pagenum)
    if newpage:
        ensureDir(basedir)
    let newposts = len(posts)
    if newposts == 0:
        logger.log(lvlInfo, fmt"No new posts written for topic: {topic}")
        return
    # only write articles after having saved LSH
    # to avoid duplicates. It is fine to add articles to the set
    # even if we don't publish them, but we never want duplicates
    saveLS(topic, lsh)
    logger.log(lvlInfo, fmt"Writing {newposts} articles for topic: {topic}")
    for (tree, a) in posts:
        writeHtml(basedir, a.slug, tree)
    # after writing the new page, ensure home points to the new page
    if newpage:
        ensureHome(topic, pagenum)
    # if its a new page, the page posts count is equivalent to the just published count
    var pagecount: int
    pagecount = newposts
    if not newpage:
        # add previous published articles
        let pagesize = ut.get_page_size(topic, pagenum)
        # In case we didn't save the count, re-read from disk
        if not pyisnone(pagesize):
            pagecount += pagesize[0].to(int)
    discard ut.update_page_size(topic, pagenum, pagecount)

    finalizePages(topic, pagenum, newpage, pagecount)

proc resetTopic(topic: string) =
    discard ut.reset_topic(topic)
    saveLS(topic, initLS())

proc pubAllPages(topic: string, clear = true) =
    ## Starting from the homepage, rebuild all archive pages, and their articles
    let grp = ut.topic_group(topic)
    let topdir = max(grp[$topicData.pages].shape[0].to(int)-1, 0)
    let numdone = max(len(grp[$topicData.done]) - 1, 0)
    assert topdir == numdone, fmt"{topdir}, {numdone}"
    if clear:
        for d in walkDirs(SITE_PATH / topic / "*"):
            removeDir(d)
        let topic_path = SITE_PATH / topic
        for n in 0..topdir:
            ensureDir(topic_path / $n)
    block:
        let pagecount = pageSize(topic, topdir)
        pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true)
    for n in 0..topdir - 1:
        let pagenum = n
        var pagecount = pageSize(topic, n)
        pubPage(topic, $pagenum, pagecount, finalize = true, with_arts = true)
    ensureHome(topic, topdir)

proc refreshPageSizes(topic: string) =
    let grp = ut.topic_group(topic)
    let donearts = grp[$topicData.done]
    assert isa(donearts, ut.za.Group)
    assert len(donearts) == len(grp[$topicData.pages])
    let topdir = len(donearts) - 1
    for pagenum in countup(0, topdir - 1):
        discard ut.update_page_size(topic, pagenum, len(donearts[$pagenum]), final = true)
    discard ut.update_page_size(topic, topdir, len(donearts[$topdir]), final = false)

when isMainModule:
    let topic = "vps"
    # refreshPageSizes(topic)
    # publish(topic)
    # assert not pyisnone(arts)
    pubAllPages(topic, clear = true)


    # var path = SITE_PATH / "index.html"
    # writeFile(path, &("<!doctype html>\n{buildPost()}"))
