import nimpy, os, nimdbx, strutils, std/importutils, chronos, std/enumerate
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
      logall "nimdbx: looking for key {k}"
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
    logall "nimdbx: saving key {k}"
    cast[LRUTrans](t).coll.inTransaction do (ct: CollectionTransaction):
      {.cast(gcsafe).}:
        ct[k] = v
      ct.commit()
    debug "nimdbx: commited key {k}"

proc initStatsDB*(): StatsDB =
  let dbpath = DATA_PATH / "sites" / WEBSITE_NAME / "stats.db"
  translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
  debug "cache: storing stats at {dbpath}"
  translate_db.DB_PATH[] = dbpath
  var db = initLRUTrans()
  openDB(db, kt = StringKeys)
  result = cast[StatsDB](db)

proc initStats*()  =
  try:
    if statsDB.isnil:
      statsDB = create(StatsDB)
      statsDB[] = initStatsDB()
  except Exception:
    logexc()
    qdebug "stats: init failed."

proc `[]=`*[K, V](c: ptr StatsDB, k: K, v: V) {.inline.} =
  c[][k] = v

proc `[]`*(c: ptr StatsDB, k: string): int32 {.inline.} =
  max(0, c[].getImpl(k, false))

proc del*[K](c: ptr StatsDB, k: K) {.gcsafe.} =
  withLock(tLock):
    cast[LRUTrans](c[]).coll.inTransaction do (ct: CollectionTransaction):
        {.cast(gcsafe).}:
          discard ct.del(k.asData)
        ct.commit()

proc del*(c: ptr StatsDB, capts: UriCaptures) {.gcsafe.} =
  {.cast(gcsafe).}:
    c.del(join([capts.topic, capts.art]))

proc updateHits*(capts: UriCaptures) =
  let ak = join([capts.topic, capts.art])
  let tk = capts.topic
  var
    artCount: int32 = statsDB[ak]
    topicCount: int32 = statsDB[tk]
  artCount += 1
  topicCount += 1
  statsDB[ak] = artCount
  statsDB[tk] = topicCount

proc getHits*(topic: string, slug: string): int32 =
  checkNil(statsDB):
    result = statsDB[join([topic, slug])]

import std/algorithm
proc cmp(x, y: (string, int32)): bool {.inline.} = x[1] > y[1]
proc showStats*(topic: string, count = 10, dosort = true) {.async.} =
  var counts: seq[(string, int32)]
  for n, (art, artslug) in enumerate await publishedArticles[string](topic, "slug"):
    counts.add (artslug, topic.getHits(artslug))
  if dosort:
    counts.sort(cmp)
  echo counts


when isMainModule:
  initStats()
  waitFor showStats("mini")

# when isMainModule:
#     initStats()
#     statsDB["test-asjkdlasd-asdkjsal"] = int32(1)
#     statsDB.del("test-asjkdlasd-asdkjsal")
