import std/[os, strutils, hashes, enumerate]
import chronos
from std/times import gettime, Time, fromUnix, inSeconds, `-`
from chronos/timer import seconds, Duration

import server_types,
    cfg, types, utils, topics, pyutils, publish, quirks, stats, articles, cache,
        sitemap, translate_types, osutils


proc pubTask*(): Future[void] {.gcsafe, async.} =
  var n, prevSize: int
  when false:
    while true:
      warn "PUBLISHING DISABLED"
      await sleepAsync(100.seconds)
  try:
    syncTopics()
    # Give some time to services to warm up
    # await sleepAsync(10.seconds)
    let t = getTime()
    var backoff = 1
    # start the topic sync thread from python
    withPyLock:
      let watcher = site.getAttr("topics_watcher")
      discard pySched[].initPool()
      discard pySchedApply[](watcher)

    while len(topicsCache) == 0:
      debug "pubtask: waiting for topics to be created..."
      await sleepAsync(backoff.seconds)
      syncTopics()
      backoff += 1
    # Only publish one topic every `CRON_TOPIC`
    prevSize = len(topicsCache)
    n = prevSize
  except Exception as e:
    logexc()
    warn "pubtask: init failed with error."
    quitl()
  while true:
    try:
      if n <= 0:
        syncTopics()
        n = len(topicsCache)
        # if new topics have been added clear homepage/sitemap
        if n != prevSize:
          prevSize = n
          clearSitemap()
          deletePage("")
      let topic = (await nextTopic())
      if topic != "":
        debug "pubtask: trying to publish {topic}"
        try:
          await maybePublish(topic).wait(10.seconds):
        except AsyncTimeoutError:
          discard
    except Exception as e:
      if not e.isnil:
        echo e[]
      warn "pubtask: failed!"
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
        await deleteArt(capts)
  for n in pagesToReset:
    withPyLock:
      discard site.update_pubtime(topic, n)

const cleanupInterval = (60 * 3600 * 2).seconds
proc cleanupTask*(): Future[void] {.async.} =
  while true:
    try:
      syncTopics()
      for topic in topicsCache.keys():
        await deleteLowTrafficArts(topic)
    except Exception:
      logexc()
      warn "cleanuptask: failed with error."
    await sleepAsync(cleanupInterval)

proc memWatcherTask*() {.async.} =
  while true:
    if memLimitReached():
      warn "memwatcher: mem limit ({memLimit}MB) reached!"
      quitl()
    await sleepAsync(5.seconds)

type
  TaskKind = enum pub, cleanup, mem
  TaskProc = proc(): Future[void] {.gcsafe.}
  TaskTable = Table[TaskKind, Future[void]]

proc selectTask(k: TaskKind): TaskProc =
  case k:
    of pub: pubTask
    of cleanup: cleanupTask
    of mem: memWatcherTask

proc scheduleTasks(): TaskTable =
  template addTask(t) =
    let fut = (selectTask t)()
    result[t] = fut
  # Publishes new articles for one topic every x seconds
  addTask pub
  # cleanup task for deleting low traffic articles
  addTask cleanup
  # quit when max memory usage reached
  addTask mem

proc tasksMonitorImpl() {.async.} =
  try:
    var tasks = scheduleTasks()
    while true:
      for k in tasks.keys():
        let t = tasks[k]
        if t.finished:
          if t.failed and not t.error.isnil:
            warn "task failed, restarting! {t.error[]}"
          tasks[k] = (selectTask k)()
      await sleepAsync(10.seconds)
  except:
    warn "tasks: monitor crashed"
    quitl

template runTasks*() =
  let ttbl = tasksMonitorImpl()

when isMainModule:
  import cache
  import strformat
  initCache()
  initStats()
  cleanupTask()
