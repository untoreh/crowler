import std/times, std/os, strutils

import server_types,
    cfg, types, topics, pyutils, publish, quirks, stats, articles

proc pubTask*() {.gcsafe.} =
    syncTopics()
    # Give some time to services to warm up
    sleep(10000)
    let t = getTime()
    # Only publish one topic every `CRON_TOPIC`
    while true:
        let topic = nextTopic()
        # Don't publish each topic more than `CRON_TOPIC_FREQ`
        if inHours(t - topicPubdate()) > cfg.CRON_TOPIC_FREQ:
            pubTopic(topic)
        sleep(cfg.CRON_TOPIC * 1000)

let broker = relPyImport("proxies_pb")
const proxySyncInterval = 60 * 1000
proc proxyTask*() {.gcsafe.} =
    # syncTopics()
    let syfp = broker.getAttr("sync_from_file")
    while true:
        withPyLock:
            discard syfp()
        sleep(proxySyncInterval)

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
            discard ut.update_pubtime(topic, n)

const cleanupInterval = 60 * 3600 * 2
proc cleanupTask*() =
    syncTopics()
    while true:
        for topic in topicsCache.keys():
            deleteLowTrafficArts(topic)
        sleep(cleanupInterval)

when isMainModule:
    import cache
    import strformat
    initCache()
    initStats()
    cleanupTask()
