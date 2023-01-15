import os, times, cligen, sugar
import chronos
import chronos_patches

const SERVER_MODE* {.booldefine.} = false

import server_tasks
import types, cfg, utils, pyutils, search, lsh, nativehttp, topics, shorturls, stats, cache, lazyjson

proc initMainThread() =
  initLogging()
  registerChronosCleanup()

proc initThreadBase(name: string) =
  var name =
    if name == "": os.getenv("CONFIG_NAME", "")
    else: name
  initConfig(name)
  initPy()
  initTypes()
  initCompressor()

proc initRun(name: string) =
  initThreadBase(name)
  initTopics()
  initSonic()
  initZstd()
  initHttp()
  startLSH()

proc run(name: string) =
  try:
    initRun(name)
  except:
    logexc()
    quit()
  while true:
    try:
      waitFor runTasks(@[pub, tpc], wait=true)
    except:
      logexc()
      warn "worker for site {name} crashed. restarting.."
      sleep(1000)

proc multiRun() =
  initMainThread()
  let
    sites_list = PROJECT_PATH / "config" / "sites.json"
    sites_json = readFile(PROJECT_PATH / "config" / "sites.json")
  var (reader, input) = getJsonReader(sites_json)
  var sites: JsonNode
  try:
    sites = reader.readValue(JsonNode)
  finally:
    input.close()
  var threads: array[1024, (string, Thread[string])]
  var nRunning = 0
  for (domain, name_port) in sites.pairs():
    let (name, _) = (name_port[0].to(string), name_port[1])
    if len(name) > 0:
      info "Creating worker thread for site {name}."
      createThread(threads[nRunning][1], run, name,)
      threads[nRunning][0].add name
      nRunning.inc
    doassert nRunning < len(threads), "Reached max number of concurrent publishers (1024)"
  info "Running indefinitely..."
  while true:
    for i in 0..<nRunning:
      if not threads[i][1].running and len(threads[i][0]) > 0:
        warn "Worker for site {threads[i][0]} is not running!, restarting..."
        quit()
    sleep(5000)


proc cleanupImpl() {.async.} =
  initThreadBase(os.getenv("CONFIG_NAME", ""))
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
  dispatchMulti([run], [multiRun], [purge], [clearcache], [compactdata])
