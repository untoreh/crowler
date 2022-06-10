import nimpy, os, nimdbx, strutils, std/importutils
import
    utils,
    quirks,
    cfg,
    types,
    translate_db,
    server_types,
    topics

export translate_db
type StatsDB {.borrow: `.`.} = distinct LRUTrans
var statsDB*: ptr StatsDB

privateAccess(LRUTrans)
proc getImpl(t: StatsDB, k: string, throw: static bool): int32 =
    withLock(tLock):
        var o: seq[byte]
        cast[LRUTrans](t).coll.inSnapshot do (cs: CollectionSnapshot):
            debug "nimdbx: looking for key {k}"
            o.add cs[k.asData].asByteSeq
        if len(o) > 0:
            result = o.asInt32
            debug "nimdbx: got key {k}, with {o.len} bytes"
        elif throw:
            raise newException(KeyError, "nimdbx: key not found")
        else:
            result = int32.low

proc `[]=`*(t: StatsDB, k: string, v: int32) {.gcsafe.} =
    withLock(tLock):
        debug "nimdbx: saving key {k}"
        cast[LRUTrans](t).coll.inTransaction do (ct: CollectionTransaction):
            {.cast(gcsafe).}:
                ct[k] = v
            ct.commit()
        debug "nimdbx: commited key {k}"

proc initStatsDB*(): StatsDB =
    let dbpath = DATA_PATH / (WEBSITE_DOMAIN & ".stats.db")
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    debug "cache: storing stats at {dbpath}"
    translate_db.DB_PATH[] = dbpath
    var db = initLRUTrans()
    openDB(db, kt = StringKeys)
    result = cast[StatsDB](db)

proc initStats*() {.raises: [].} =
    try:
        if statsDB.isnil:
            let sdb {.global.} = initStatsDB()
            statsDB = sdb.unsafeAddr
    except:
        qdebug "{getCurrentExceptionMsg()}"

proc `[]=`*[K, V](c: ptr StatsDB, k: K, v: V) {.inline.} =
    c[][k] = v

proc `[]`*(c: ptr StatsDB, k: string): int32 {.inline.} =
    max(0, c[].getImpl(k, false))

proc del*[K](c: ptr StatsDB, k: K) =
    withLock(tLock):
        cast[LRUTrans](c[]).coll.inTransaction do (ct: CollectionTransaction):
            ct.del(k.asData)
            ct.commit()

proc del*(c: ptr StatsDB, capts: UriCaptures) =
    c.del(join([capts.topic, capts.art]))

proc updateHits*(capts: UriCaptures) =
    let ak = join([capts.topic, capts.art])
    let tk = capts.topic
    var
        art_count: int32 = statsDB[ak]
        topic_count: int32 = statsDB[tk]
    art_count += 1
    topic_count += 1
    statsDB[ak] = art_count
    statsDB[tk] = topic_count

proc getHits*(topic: string, slug: string): int32 =
    statsDB[join([topic, slug])]

proc showStats(topic: string) =
    for (art, artslug) in publishedArticles[string](topic, "slug"):
        echo artslug
        echo topic.getHits(artslug)


when isMainModule:
    initStats()
    showStats("vps")

# when isMainModule:
#     initStats()
#     statsDB["test-asjkdlasd-asdkjsal"] = int32(1)
#     statsDB.del("test-asjkdlasd-asdkjsal")
