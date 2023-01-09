import std/[os, strutils, hashes, enumerate]
import chronos
from std/times import gettime, Time, fromUnix, inSeconds, `-`
from chronos/timer import seconds, Duration

import server_types,
    cfg, types, utils, topics, pyutils, publish, quirks, stats, articles, cache,
        sitemap, translate_types, osutils


proc pubTask*(): Future[void] {.gcsafe, async.} =
  initPublish()
  var n, prevSize: int
  when false:
    while true:
      warn "PUBLISHING DISABLED"
      await sleepAsync(100.seconds)
  try:
    # Give some time to services to warm up
    # await sleepAsync(10.seconds)
    let t = getTime()
    var backoff = 1
    while len(topicsCache) == 0:
      debug "pubtask: waiting for topics to be created..."
      await sleepAsync(backoff.seconds)
      backoff += 1
    # Only publish one topic every `CRON_TOPIC`
    prevSize = len(topicsCache)
    n = prevSize
  except:
    logexc()
    warn "pubtask: init failed with error."
    quitl()
  while true:
    try:
      if n <= 0:
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
    await sleepAsync(PUB_TASK_THROTTLE.seconds)
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
    elif inSeconds(now - pubTime) > config.cleanupAge:
      let hits = topic.getHits(capts.art)
      # article has low hit count
      if hits < config.cleanupHits:
        await deleteArt(capts)
  for n in pagesToReset:
    withPyLock:
      discard site.update_pubtime(topic, n)

const cleanupInterval = (60 * 3600 * 2).seconds
proc cleanupTask*(): Future[void] {.async.} =
  while true:
    try:
      for topic in topicsCache.keys():
        await deleteLowTrafficArts(topic)
    except Exception:
      logexc()
      warn "cleanuptask: failed with error."
    await sleepAsync(cleanupInterval)

# gc
pygil.globalAcquire()
pyObjPtr (pyGC, pyImport("gc"))
doassert not isnil(pyGC)
pygil.release()
proc memWatcherTask*() {.async.} =
  initPy()
  while true:
    withPylock:
      discard pyGC[].collect()
    if memLimitReached():
      warn "memwatcher: mem limit ({memLimit}MB) reached!"
      quitl()
    await sleepAsync(5.seconds)

proc topicsTask*() {.async.} =
  await syncTopics()
  try:
    var topic_file: string
    withPyLock:
      topic_file = $site.getAttr("last_topic_file")
    var lastModTime = getLastModificationTime(topic_file)
    while true:
      let modtime = getLastModificationTime(topic_file)
      if modtime != lastModTime:
        await syncTopics(true)
        lastModTime = modtime
      await sleepAsync(1.minutes)
  except:
    logexc()

type
  TaskKind* = enum pub, cleanup, mem, tpc
  TaskProc = proc(): Future[void] {.gcsafe.}
  TaskTable = Table[TaskKind, Future[void]]

proc selectTask(k: TaskKind): TaskProc =
  case k:
    # Publishes new articles for one topic every x seconds
    of pub: pubTask
    # cleanup task for deleting low traffic articles
    of cleanup: cleanupTask
    # quit when max memory usage reached
    of mem: memWatcherTask
    # syncs topics
    of tpc: topicsTask

proc scheduleTasks*(tasks: seq[TaskKind]): TaskTable =
  template addTask(t) =
    let fut = (selectTask t)()
    result[t] = fut
  for task in tasks:
    addTask task

proc tasksMonitorImpl(tasks: seq[TaskKind]) {.async.} =
  try:
    var tasks = scheduleTasks(tasks)
    while true:
      for k in tasks.keys():
        let t = tasks[k]
        if t.finished:
          if t.failed and not t.error.isnil:
            warn "task failed, restarting!"
          tasks[k] = (selectTask k)()
      await sleepAsync(10.seconds)
  except:
    warn "tasks: monitor crashed"
    quitl

template runTasks*(tasks = @[pub, cleanup, mem], wait: static[bool] = false): untyped =
  when wait:
    tasksMonitorImpl(tasks)
  else:
    let ttbl = tasksMonitorImpl(tasks)
