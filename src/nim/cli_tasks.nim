import chronos
import cligen

const SERVER_MODE* {.booldefine.} = false

import server_tasks
import pyutils, search, lsh, nativehttp, topics, shorturls, stats

proc init() =
  initTopics()
  initZstd()

proc run() =
  init()
  initSonic()
  initHttp()
  startLSH()
  waitFor runTasks(@[pub, tpc, mem], wait=true)

proc cleanupImpl() {.async.} =
  init()
  var futs: seq[Future[void]]
  for topic in topicsCache.keys():
    futs.add deleteLowTrafficArts(topic)
  await allFutures(futs)

proc purge*() = waitFor cleanupImpl()

when isMainModule:
  dispatchMulti([run], [purge])
