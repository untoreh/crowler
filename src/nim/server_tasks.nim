import std/times, std/os, strutils, hashes

import server_types,
    cfg, types, topics, pyutils, publish, quirks, stats, articles, cache, sitemap, translate_types, server_types

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

proc pubTask*() {.gcsafe.} =
    syncTopics()
    # Give some time to services to warm up
    sleep(10000)
    let t = getTime()
    var backoff = 1000
    # start the topic sync thread from python
    discard pysched.apply(site.topics_watcher)

    while len(topicsCache) == 0:
        debug "pubtask: waiting for topics to be created..."
        sleep(backoff)
        syncTopics()
        backoff += 1000
    # Only publish one topic every `CRON_TOPIC`
    var
        prev_size = len(topicsCache)
        n = prev_size
    while true:
        if n == 0:
            syncTopics()
            n = len(topicsCache)
            # if new topics have been added clear homepage/sitemap
            if n != prev_size:
                prev_size = n
                clearSitemap("")
                deletePage("")
        let topic = nextTopic()
        # Don't publish each topic more than `CRON_TOPIC_FREQ`
        debug "pubtask: {topic} was published {inHours(t - topicPubdate())} hours ago."
        if inHours(t - topicPubdate()) > cfg.CRON_TOPIC_FREQ:
            if pubTopic(topic):
                # clear homepage and topic page cache
                deletePage("")
                deletePage("/" & topic)
        sleep(cfg.CRON_TOPIC * 1000)
        n -= 1

proc deleteLowTrafficArts*(topic: string) {.gcsafe.} =
    let now = getTime()
    var
        pagenum: int
        pagesToReset: seq[int]
        pubTime: Time
        pubTimeTs: int
    var capts = mUriCaptures()
    capts.topic = topic
    for (art, _) in publishedArticles[string](topic, ""):
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
                    deleteArt(capts)
    for n in pagesToReset:
        withPyLock:
            discard site.update_pubtime(topic, n)

const cleanupInterval = 60 * 3600 * 2
proc cleanupTask*() =
    while true:
        syncTopics()
        for topic in topicsCache.keys():
            deleteLowTrafficArts(topic)
        sleep(cleanupInterval)

when isMainModule:
    import cache
    import strformat
    initCache()
    initStats()
    cleanupTask()
