import nimpy, os, times, strutils, std/importutils, chronos, std/enumerate
import
  utils,
  quirks,
  cfg,
  types,
  translate_db,
  server_types,
  topics,
  data

export translate_db
var statsDB*: LockDB

proc initStatsDB*(): LockDB =
  let dbpath = WEBSITE_PATH / "stats.db"
  debug "cache: storing stats at {dbpath}"
  result = init(LockDB, dbpath, ttl = initDuration(weeks = 1000))

proc initStats*()  =
  try:
    setNil(statsDB):
      initStatsDB()
  except Exception:
    logexc()
    qdebug "stats: init failed."

proc del*(c: LockDB, capts: UriCaptures) {.gcsafe.} =
  c.delete(join([capts.topic, capts.art]))

proc updateHits*(capts: UriCaptures) =
  let ak = join([capts.topic, capts.art])
  let tk = capts.topic
  var
    artCount: uint32 = statsDB.getUnchecked(ak).toUint32
    topicCount: uint32 = statsDB.getUnchecked(tk).toUint32
  artCount += 1
  topicCount += 1
  statsDB[ak] = artCount.toString
  statsDB[tk] = topicCount.toString

proc getHits*(topic: string, slug: string): uint32 =
  checkNil(statsDB):
    result = statsDB.getUnchecked(join([topic, slug])).toUint32

import std/algorithm
proc cmp(x, y: (string, uint32)): bool {.inline.} = x[1] > y[1]
proc showStats*(topic: string, count = 10, dosort = true) {.async.} =
  var counts: seq[(string, uint32)]
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
#     statsDB["test-asjkdlasd-asdkjsal"] = uint32(1)
#     statsDB.del("test-asjkdlasd-asdkjsal")
