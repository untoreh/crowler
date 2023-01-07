import chronos
import os, times, cligen

const SERVER_MODE* {.booldefine.} = false

import server_tasks
import cfg, utils, pyutils, search, lsh, nativehttp, topics, shorturls, stats, cache

proc initThreadBase() =
  initConfig(os.getenv("CONFIG_NAME", ""))
  initPy()
  initTypes()
  initCompressor()
  initLogging()
  registerChronosCleanup()

proc run() =
  initThreadBase()
  initTopics()
  initSonic()
  initZstd()
  initHttp()
  startLSH()
  waitFor runTasks(@[pub, tpc, mem], wait=true)

proc cleanupImpl() {.async.} =
  init()
  var futs: seq[Future[void]]
  for topic in topicsCache.keys():
    futs.add deleteLowTrafficArts(topic)
  await allFutures(futs)

## Deletes low traffic articles
proc purge() = waitFor cleanupImpl()

## Empties to page cache
proc clearcache(force = false) =
  # Clear page cache database
  try:
    initCache(comp=true)
    pageCache.clear()
    let n = pageCache.len
    warn "cache reduced to {n} keys."
  except:
    logexc()

proc compactdata(name = "translate.db") =
  let path = config.websitePath / name
  if not fileExists(path):
    raise newException(OSError, "Database does not appear to exist")
  let db = init(LockDB, path, ttl = initDuration())
  db.compact()

when isMainModule:
  dispatchMulti([run], [purge], [clearcache], [compactdata])
