import std/os, strutils, hashes, chronos, chronos/timer
from std/times import gettime, Time, fromUnix, inSeconds, `-`
from chronos/timer import seconds, Duration

import server_types,
    cfg, types, topics, pyutils, publish, quirks, stats, articles, cache, sitemap, translate_types, server_types, chronos

proc deletePage*(relpath: string) {.gcsafe.} =
    let
        sfx = relpath.suffixPath()
        fpath = SITE_PATH / sfx
        fkey = fpath.hash
    {.cast(gcsafe).}:
        pageCache[].del(fkey)
        pageCache[].del(hash(SITE_PATH / "amp" / sfx))
        for lang in TLangsCodes:
            pageCache[].del(hash(SITE_PATH / "amp" / lang / sfx))
            pageCache[].del(hash(SITE_PATH / lang / sfx))

proc pubTask*(): Future[void] {.gcsafe, async.} =
    await syncTopics()
    # Give some time to services to warm up
    await sleepAsync(10.seconds)
    let t = getTime()
    var backoff = 1
    # start the topic sync thread from python
    withPyLock:
        discard pysched[].apply(site[].topics_watcher)

    while len(topicsCache) == 0:
        debug "pubtask: waiting for topics to be created..."
        await sleepAsync(backoff.seconds)
        await syncTopics()
        backoff += 1
    # Only publish one topic every `CRON_TOPIC`
    var
        prev_size = len(topicsCache)
        n = prev_size
    while true:
        if n <= 0:
            await syncTopics()
            n = len(topicsCache)
            # if new topics have been added clear homepage/sitemap
            if n != prev_size:
                prev_size = n
                clearSitemap("")
                deletePage("")
        let topic = (await nextTopic())
        if topic != "":
            # Don't publish each topic more than `CRON_TOPIC_FREQ`
            debug "pubtask: {topic} was published {inHours(t - topicPubdate())} hours ago."
            if await maybePublish(topic):
                # clear homepage and topic page cache
                deletePage("")
                deletePage("/" & topic)
                discard
        await sleepAsync(cfg.CRON_TOPIC.seconds)
        n -= 1

proc deleteLowTrafficArts*(topic: string): Future[void] {.gcsafe, async.} =
    let now = getTime()
    var
        pagenum: int
        pagesToReset: seq[int]
        pubTime: Time
        pubTimeTs: int
    var capts = mUriCaptures()
    capts.topic = topic
    for (art, _) in (await publishedArticles[string](topic, "")):
        withPyLock:
            if pyisnone(art):
                continue
            capts.art = pyget[string](art, "slug")
            pagenum = pyget(art, "page", 0)
        capts.page = pagenum.intToStr
        try:
            withPyLock:
                pubTimeTs = pyget(art, "pubTime", 0)
            pubTime = fromUnix(pubTimeTs)
        except:
            pubTime = default(Time)
        if pubTime == default(Time):
            if not (pagenum in pagesToReset):
                debug "tasks: resetting pubTime for page {pagenum}"
                pagesToReset.add pagenum
        # article is old enough
        elif inSeconds(now - pubTime) > cfg.CLEANUP_AGE:
            let hits = topic.getHits(capts.art)
            # article has low hit count
            if hits < cfg.CLEANUP_HITS:
                {.cast(gcsafe).}:
                    await deleteArt(capts)
    for n in pagesToReset:
        withPyLock:
            discard site[].update_pubtime(topic, n)

const cleanupInterval = (60 * 3600 * 2).seconds
proc cleanupTask*(): Future[void] {.async.} =
    while true:
        await syncTopics()
        for topic in topicsCache.keys():
            await deleteLowTrafficArts(topic)
        await sleepAsync(cleanupInterval)

when isMainModule:
    import cache
    import strformat
    initCache()
    initStats()
    cleanupTask()
