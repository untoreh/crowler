import nimpy,
       os,
       sugar,
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
       types,
       utils,
       html,
       rss,
       topics,
       articles,
       cache,
       search,
       pyutils

privateAccess(LocalitySensitive)
let pageset = initLockTable[string, bool]()

include "pages"

proc ensureDir(dir: string) =
    if not dirExists(dir):
        if fileExists(dir):
            info "Deleting file that should be a directory {dir}"
            removeFile(dir)
        info "Creating directory {dir}"
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

proc pubPageFromTemplate(tpl: string, title: string, vars: seq[(string, string)] = tplRep, desc = "") =
    var txt = readfile(ASSETS_PATH / "templates" / tpl)
    txt = multiReplace(txt, vars)
    let slug = slugify(title)
    let p = buildPage(title = title, content = txt)
    processHtml("", slug, p)

proc pubInfoPages() =
    ## Build DMCA, TOS, and GPDR pages
    pubPageFromTemplate("dmca.html", "DMCA", desc = fmt"DMCA compliance for {WEBSITE_DOMAIN}")
    pubPageFromTemplate("tos.html", "Terms of Service",
            desc = fmt"Terms of Service for {WEBSITE_DOMAIN}")
    pubPageFromTemplate("privacy-policy.html", "Privacy Policy", ppRep,
            desc = "Privacy Policy for {WEBSITE_DOMAIN}")


proc curPageNumber(topic: string): int =
    withPyLock:
        return ut.get_top_page(topic).to(int)
    # return getSubdirNumber(topic, curdir)

proc pubPage(topic: string, pagenum: string, pagecount: int, finalize = false, istop = false,
        with_arts = false) =
    ## Writes a single page (fetching its related articles, if its not a template) to storage
    topicPage(topic, pagenum, istop)

    info "Updating page:{pagenum} for topic:{topic} with entries:{pagecount}"
    processHTML(topic,
                pagenum / "index",
                pagetree)
    # if we pass a pagecount we mean to finalize
    if finalize:
        withPyLock:
            discard ut.update_page_size(topic, pagenum.parseInt, pagecount, final = true)
    if with_arts:
        for a in arts:
            processHtml(topic / pagenum, a.slug, buildPost(a), a)

proc finalizePages(topic: string, pn: int, newpage: bool, pagecount: var int) =
    ## Always update both the homepage and the previous page
    let pages = topicPages(topic)
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
#     let done = topicDonePages(topic)
#     withPyLock:
#         assert isa(done, ut.za.Group)
#         let topdir = len(done)
#         if topdir == 0:
#             return
#         var i = 0
#         var newdone = newSeq[PyObject]()
#         for k in done.keys():
#             let pagedone = done[k]
#             newdone.add()

proc filterDuplicates(topic: string, lsh: LocalitySensitive, pagenum: int,
                      posts: var seq[(VNode, Article)],
                      donePy: var seq[PyObject],
                      doneArts: var seq[Article]): bool {.gcsafe.} =
    var arts = getArticles(topic, pagenum = pagenum)
    if arts.len == 0:
        return false
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
            a.slug = uslug
            a.title = utitle
            a.page = pagenum
            posts.add((buildPost(a), a))
            withPyLock:
                a.py["slug"] = uslug
                a.py["title"] = utitle
                a.py["page"] = pagenum
    # update done articles after uniqueness checks
    withPyLock:
        for (_, a) in posts:
            donePy.add a.py
            doneArts.add a
    updateTopicPubdate()
    withPyLock:
        discard ut.save_done(topic, len(arts), donePy, pagenum)
    true

proc pubTopic*(topic: string) {.gcsafe.} =
    ##  Generates html for a list of `Article` objects and writes to file.
    withPyLock:
        doassert topic in ut.load_topics()[1]
    info "pub: topic - {topic}"
    var pagenum = curPageNumber(topic)
    let newpage = pageSize(topic, pagenum) > cfg.MAX_DIR_FILES
    if newpage:
        pagenum += 1
    # The subdir (at $pagenum) at this point must be already present on storage
    let pagedir = topic / $pagenum

    let lsh = loadLS(topic)
    let startTime = getTime()
    var
        posts: seq[(VNode, Article)]
        donePy: seq[PyObject]
        doneArts: seq[Article]
    while posts.len == 0 and (getTime() - startTime).inSeconds < cfg.PUBLISH_TIMEOUT:
        if not filterDuplicates(topic, lsh, pagenum, posts, donePy, doneArts):
            break

    # At this point articles "state" is updated on python side
    # new articles are "published" and the state (pagecache, rss, search) has to be synced
    when not cfg.SERVER_MODE:
        if newpage:
            ensureDir(SITE_PATH / pagedir)
    let newposts = len(posts)
    if newposts == 0:
        info "No new posts written for topic: {topic}"
        return
    # only write articles after having saved LSH (within `filterDuplicates)
    # to avoid duplicates. It is fine to add articles to the set
    # even if we don't publish them, but we never want duplicates
    saveLS(topic, lsh)
    info "Writing {newposts} articles for topic: {topic}"
    # FIXME: should this be here?
    for (tree, a) in posts:
        processHtml(pagedir, a.slug, tree, a)
    # after writing the new page, ensure home points to the new page
    when not cfg.SERVER_MODE:
        if newpage:
            ensureHome(topic, pagenum)
    # if its a new page, the page posts count is equivalent to the just published count
    var pagecount: int
    pagecount = newposts
    withPyLock:
        if not newpage:
            # add previous published articles
            let pagesize = ut.get_page_size(topic, pagenum)
            # In case we didn't save the count, re-read from disk
            if not pyisnone(pagesize):
                pagecount += pagesize[0].to(int)
        discard ut.update_page_size(topic, pagenum, pagecount)

    finalizePages(topic, pagenum, newpage, pagecount)
    # update feed file
    when cfg.RSS:
        let tfeed = topic.fetchFeed
        tfeed.update(topic, doneArts, dowrite = true)
    when cfg.SEARCH_ENABLED:
        for ar in doneArts:
            var relpath = topic / $pagenum / ar.slug
            search.push(relpath)
    # update ydx turbo items
    when cfg.YDX:
        writeFeed()
    info "pub: published {len(doneArts)} new posts."

let lastPubTime = create(Time)
var pubLock: Lock
initLock(pubLock)
lastPubTime[] = getTime()
proc pub*() {.gcsafe.} =
    let t = getTime()
    if pubLock.tryacquire:
        defer: pubLock.release
        syncTopics()
        # Only publish one topic every `CRON_TOPIC`
        if inSeconds(t - lastPubTime[]) > cfg.CRON_TOPIC:
            lastPubTime[] = t
            let topic = nextTopic()
            # Don't publish each topic more than `CRON_TOPIC_FREQ`
            if inHours(t - topicPubdate()) > cfg.CRON_TOPIC_FREQ:
                pubTopic(topic)

proc resetTopic(topic: string) =
    withPyLock:
        discard ut.reset_topic_data(topic)
    pageCache[].del(topic.feedKey)
    saveLS(topic, initLS())

proc pubAllPages(topic: string, clear = true) =
    ## Starting from the homepage, rebuild all archive pages, and their articles
    let (topdir, numdone) = topic.getState
    assert topdir == numdone, fmt"{topdir}, {numdone}"
    if clear:
        for d in walkDirs(SITE_PATH / topic / "*"):
            removeDir(d)
        let topic_path = SITE_PATH / topic
        for n in 0..topdir:
            ensureDir(topic_path / $n)
    block:
        let pagecount = pageSize(topic, topdir)
        pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true, istop = true)
    for n in 0..<topdir:
        let pagenum = n
        var pagecount = pageSize(topic, n)
        pubPage(topic, $pagenum, pagecount, finalize = true, with_arts = true)
    ensureHome(topic, topdir)

# proc refreshPageSizes(topic: string) =
#     withPyLock:
#         let grp = ut.topic_group(topic)
#         let donearts = grp[$topicData.done]
#         assert isa(donearts, ut.za.Group)
#         assert len(donearts) == len(grp[$topicData.pages])
#         let topdir = len(donearts) - 1
#         for pagenum in 0..<topdir:
#             discard ut.update_page_size(topic, pagenum, len(donearts[$pagenum]), final = true)
#         discard ut.update_page_size(topic, topdir, len(donearts[$topdir]), final = false)

# import translate
when isMainModule:
    let topic = "vps"
    # refreshPageSizes(topic)
    # resetTopic("web")
    # resetTopic("vps")
    # resetTopic("dedi")
    dopublish(topic)
    quit()
    let
        topdir = 0
        pagecount = pageSize(topic, topdir)
    # pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true)
    # pubPageFromTemplate("dmca.html", "DMCA")
