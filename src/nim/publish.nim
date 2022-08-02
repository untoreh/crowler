import nimpy,
       os,
       sugar,
       times,
       strutils,
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
       pyutils,
       sitemap

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
    DATA_PATH / "sites" / WEBSITE_NAME / "topics" / topic / "lsh"

import zstd / [compress, decompress]
type
    CompressorObj = object of RootObj
        zstd_c: ptr ZSTD_CCtx
        zstd_d: ptr ZSTD_DCtx
    Compressor = ptr CompressorObj

when defined(gcDestructors):
    proc `=destroy`(c: var CompressorObj) =
        if not c.zstd_c.isnil:
            discard free_context(c.zstd_c)
        if not c.zstd_d.isnil:
            discard free_context(c.zstd_d)

let comp = create(CompressorObj)
comp.zstd_c = new_compress_context()
comp.zstd_d = new_decompress_context()

proc compress[T](v: T): seq[byte] = compress(comp.zstd_c, v, level = 2)
proc decompress[T](v: sink seq[byte]): T = cast[T](decompress(comp.zstd_d, v))
proc decompress[T](v: sink string): T = cast[T](decompress(comp.zstd_d, v))

proc saveLS(topic: string, lsh: LocalitySensitive[uint64]) =
    let path = getLSPath(topic)
    createDir(path)
    let lshJson = $$lsh
    writeFile(path / "lsh.json.zst", compress(lshJson))

proc loadLS(topic: string): LocalitySensitive[uint64] =
    var lspath = getLSPath(topic) / "lsh.json.zst"
    var data: string
    if fileExists(lspath):
        let f = readFile(lspath)
        data = decompress[string](f)
    else:
        lspath = lspath[0..^5]
        if fileExists(lspath):
            data = readFile(lspath)
    if data.len != 0:
        var lsh = to[LocalitySensitive[uint64]](data)
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

proc curPageNumber(topic: string): Future[int] {.async.} =
    withPyLock:
        return site[].get_top_page(topic).to(int)
    # return getSubdirNumber(topic, curdir)

proc pubPage(topic: string, pagenum: string, pagecount: int, finalize = false, istop = false,
        with_arts = false) {.async.} =
    ## Writes a single page (fetching its related articles, if its not a template) to storage
    topicPage(topic, pagenum, istop)

    info "Updating page:{pagenum} for topic:{topic} with entries:{pagecount}"
    await processHTML(topic,
                pagenum / "index",
                pagetree)
    # if we pass a pagecount we mean to finalize
    if finalize:
        withPyLock:
            discard site[].update_page_size(topic, pagenum.parseInt, pagecount, final = true)
    if with_arts:
        for a in arts:
            await processHtml(topic / pagenum, a.slug, (await buildPost(a)), a)

proc finalizePages(topic: string, pn: int, newpage: bool, pagecount: ptr int) {.async.} =
    ## Always update both the homepage and the previous page
    let pages = await topicPages(topic)
    var pagenum = pn.intToStr
    # current articles count
    let pnStr = pagenum
    let pn = pagenum.parseInt
    # the current page is the homepage
    await pubPage(topic, pnStr, pagecount[])
    # Also build the previous page if we switched page
    if newpage:
        # make sure the second previous page is finalized
        let pn = pagenum.parseInt
        if pn > 1:
            var pagesize: PyObject
            var final: bool
            withPyLock:
                pagesize = pages[pn-2]
                pagecount[] = pagesize[0].to(int)
                final = pagesize[1].to(bool)
            if not final:
                pagenum = (pn-2).intToStr
                await pubPage(topic, pagenum, pagecount[], finalize = true)
        # now update the just previous page
        withPyLock:
            pagecount[] = pages[pn-1][0].to(int)
        pagenum = (pn-1).intToStr
        await pubPage(topic, pagenum, pagecount[], finalize = true)

# proc resetPages(topic: string) =
#     ## Takes all the published articles in `done`
#     ## and resets their page numbers
#     let done = topicDonePages(topic)
#     withPyLock:
#         assert isa(done, site[].za.Group)
#         let topdir = len(done)
#         if topdir == 0:
#             return
#         var i = 0
#         var newdone = newSeq[PyObject]()
#         for k in done.keys():
#             let pagedone = done[k]
#             newdone.add()

proc filterDuplicates(topic: string, lsh: LocalitySensitive, pagenum: int,
                      posts: ptr seq[(VNode, Article)],
                      donePy: ptr seq[PyObject],
                      doneArts: ptr seq[Article]): Future[bool] {.gcsafe, async.} =
    var arts = await getArticles(topic, pagenum = pagenum)
    let pubtime = getTime().toUnix
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
            if a.topic == "":
                a.topic = topic
                a.py["topic"] = topic
            posts[].add(((await buildPost(a)), a))
            withPyLock:
                a.py["slug"] = uslug
                a.py["title"] = utitle
                a.py["page"] = pagenum
                a.py["pubTime"] = pubtime
    # update done articles after uniqueness checks
    withPyLock:
        for (_, a) in posts[]:
            donePy[].add a.py
            doneArts[].add a
    await updateTopicPubdate()
    withPyLock:
        discard site[].save_done(topic, len(arts), donePy[], pagenum)
    return true

proc pubTopic*(topic: string): Future[bool] {.gcsafe, async.} =
    ##  Generates html for a list of `Article` objects and writes to file.
    withPyLock:
        doassert topic in site[].load_topics()[1]
    info "pub: topic - {topic}"
    var pagenum = await curPageNumber(topic)
    let newpage = (await pageSize(topic, pagenum)) > cfg.MAX_DIR_FILES
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
        if not await filterDuplicates(topic, lsh, pagenum, posts.addr, donePy.addr, doneArts.addr):
            break

    # At this point articles "state" is updated on python side
    # new articles are "published" and the state (pagecache, rss, search) has to be synced
    when not cfg.SERVER_MODE:
        if newpage:
            ensureDir(SITE_PATH / pagedir)
    let newposts = len(posts)
    if newposts == 0:
        info "No new posts written for topic: {topic}"
        return false
    # only write articles after having saved LSH (within `filterDuplicates)
    # to avoid duplicates. It is fine to add articles to the set
    # even if we don't publish them, but we never want duplicates
    saveLS(topic, lsh)
    info "Writing {newposts} articles for topic: {topic}"
    # FIXME: should this be here?
    for (tree, a) in posts:
        await processHtml(pagedir, a.slug, tree, a)
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
            let pagesize = site[].get_page_size(topic, pagenum)
            # In case we didn't save the count, re-read from disk
            if not pyisnone(pagesize):
                pagecount += pagesize[0].to(int)
        discard site[].update_page_size(topic, pagenum, pagecount)

    await finalizePages(topic, pagenum, newpage, pagecount.addr)
    # update feed file
    when cfg.RSS:
        let tfeed = await topic.fetchFeed
        tfeed.update(topic, doneArts, dowrite = true)
    when cfg.SEARCH_ENABLED:
        for ar in doneArts:
            var relpath = topic / $pagenum / ar.slug
            await search.push(relpath)
    clearSiteMap(topic)
    # update ydx turbo items
    when cfg.YDX:
        writeFeed()
    info "pub: published {len(doneArts)} new posts."
    return true


let lastPubTime = create(Time)
var pubLock: Lock
initLock(pubLock)
lastPubTime[] = getTime()
let siteCreated = create(Time)
try:
    syncPyLock:
        assert pyhasAttr(site[], "created"), "site does not have creation date"
        siteCreated[] = parse(site[].created.to(string), "yyyy-MM-dd").toTime
except:
    warn getCurrentException()[]
    siteCreated[] = fromUnix(0)
proc pubTimeInterval(): int =
    ## This formula gradually reduces the interval between publications
    max(cfg.CRON_TOPIC_FREQ_MIN, cfg.CRON_TOPIC_FREQ_MAX - ((getTime() - siteCreated[]).inMinutes.int.div (3600 * 24) * 26))

proc maybePublish*(topic: string): Future[bool] {.gcsafe, async.} =
    let t = getTime()
    if pubLock.tryacquire:
        defer: pubLock.release
        # Don't publish each topic more than `CRON_TOPIC_FREQ`
        if inHours(t - (await topicPubdate())) > pubTimeInterval():
            lastPubTime[] = t
            return await pubTopic(topic)

proc resetTopic(topic: string) =
    syncPyLock():
        discard site[].reset_topic_data(topic)
    pageCache[].del(topic.feedKey)
    clearSiteMap(topic)
    saveLS(topic, initLS())

proc pubAllPages(topic: string, clear = true) {.async.} =
    ## Starting from the homepage, rebuild all archive pages, and their articles
    let (topdir, numdone) = await topic.getState
    assert topdir == numdone, fmt"{topdir}, {numdone}"
    when not cfg.SERVER_MODE:
        if clear:
            for d in walkDirs(SITE_PATH / topic / "*"):
                removeDir(d)
            let topic_path = SITE_PATH / topic
            for n in 0..topdir:
                ensureDir(topic_path / $n)
    block:
        let pagecount = await pageSize(topic, topdir)
        await pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true, istop = true)
    for n in 0..<topdir:
        let pagenum = n
        var pagecount = await pageSize(topic, n)
        await pubPage(topic, $pagenum, pagecount, finalize = true, with_arts = true)
    when not cfg.SERVER_MODE:
        ensureHome(topic, topdir)

# proc refreshPageSizes(topic: string) =
#     withPyLock:
#         let grp = site[].topic_group(topic)
#         let donearts = grp[$topicData.done]
#         assert isa(donearts, site[].za.Group)
#         assert len(donearts) == len(grp[$topicData.pages])
#         let topdir = len(donearts) - 1
#         for pagenum in 0..<topdir:
#             discard site[].update_page_size(topic, pagenum, len(donearts[$pagenum]), final = true)
#         discard site[].update_page_size(topic, topdir, len(donearts[$topdir]), final = false)

# import translate
# when isMainModule:
#     let topic = "vps"
#     # refreshPageSizes(topic)
#     # resetTopic("web")
#     # resetTopic("vps")
#     # resetTopic("dedi")
#     dopublish(topic)
#     quit()
#     let
#         topdir = 0
#         pagecount = pageSize(topic, topdir)
#     # pubPage(topic, $topdir, pagecount, finalize = false, with_arts = true)
#     # pubPageFromTemplate("dmca.html", "DMCA")
