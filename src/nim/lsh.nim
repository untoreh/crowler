import std/[importutils, strutils, marshal, tables, sets, algorithm, os, monotimes, strformat], chronos,
    minhash {.all.}

import cfg, types, utils
privateAccess(LocalitySensitive)
export minhash
{.experimental: "notnil".}

type
  PublishedArticlesObj = LocalitySensitive[uint64]
  PublishedArticles* = ptr PublishedArticlesObj
var lshThread: Thread[void]

proc getLSPath(topic: string): string =
  DATA_PATH / "sites" / WEBSITE_NAME / "topics" / topic / "lsh"

proc initLS*(): PublishedArticles =
  let hasher = initMinHasher[uint64](64)
  # very small band width => always find duplicates
  let lsh = create(PublishedArticlesObj)
  checkNil(lsh):
    result = lsh
  result[] = initLocalitySensitive[uint64](hasher, 16)

proc saveLSImpl(topic: string, lsh: PublishedArticlesObj) {.async.} =
  let path = getLSPath(topic)
  createDir(path)
  let lshJson = $$lsh
  let comp = compress(lshJson)
  await writeFileAsync(path / "lsh.json.zst", comp)

proc saveLS*(topic: string, lsh: sink PublishedArticles) {.async.} =
  if lsh.isnil:
    raise newException(ValueError, "lsh can't be nil.")
  await saveLSImpl(topic, lsh[])

proc free*(lsh: PublishedArticles) =
  if not lsh.isnil:
    reset(lsh[])
    dealloc(lsh)

proc toLsh(data: string): PublishedArticlesObj =
  result = to[PublishedArticlesObj](data)
  # reinitialize minhasher since it is a cbinding func
  result.hasher = initMinHasher[uint64](64)

import json
proc fixLS(topic: string, data: string) {.async.} =
  ## This fixes a marshalling bug where the LS set was saved as a tuple (ptr, ls), to be deprecated.
  let j = data.parseJson
  if j.kind == JArray:
    if j.len > 1:
      if j[0].kind == JInt:
        if j[1].kind == JObject:
          let ls = create(PublishedArticlesObj)
          ls[] = ($j[1]).toLsh
          await saveLS(topic, ls)

proc loadLS*(topic: string): Future[PublishedArticles] {.async.} =
  var lspath = getLSPath(topic) / "lsh.json.zst"
  var data: string
  if fileExists(lspath):
    let f = await readFileAsync(lspath)
    data = decompress[string](f)
  else:
    lspath = lspath[0..^5]
    if fileExists(lspath):
      data = await readFileAsync(lspath)
  if data.len != 0:
    result = create(PublishedArticlesObj)
    checkNil(result):
      try:
        result[] = data.toLsh
      except CatchableError as e:
        warn "Couldn't load LSH for topic {topic}, trying fix."
        try:
          await fixLS(topic, data)
        except CatchableError:
          warn "Couldn't apply fix for lsh."
          raise e
  else:
    return initLS()

# these should be generalized since it's the same from `imageflow_server`
var lshIn*: LockDeque[(MonoTime, PublishedArticles, ptr string)]
var lshOut*: LockTable[(MonoTime, PublishedArticles), bool]
var ptrTracker*: ptr HashSet[pointer] # Ensures lshIn doesn't have clashing pointers since we pass string pointers

proc addArticle*(lsh: PublishedArticles, content: ptr string): Future[bool] {.async.} =
  let t = getMonoTime()
  lshIn.addLast (t, lsh, content)
  return await lshOut.popWait((t, lsh))

{.experimental: "strictnotnil".}
proc checkAndAddArticle(t: MonoTime, lsh: PublishedArticles, content: ptr string not nil) {.async.} =
  let k = (t, lsh)
  try:
    if not isDuplicate(lsh[], content[]):
      let id = $(len(lsh.fingerprints) + 1)
      lsh[].add(content[], id)
      lshOut[k] = true
    else:
      lshOut[k] = false
  except Exception as e:
    lshOut[k] = false
    if not e.isnil:
      echo e[]
    warn "lsh: error adding article."

proc asyncLshHandler() {.async.} =
  try:
    var
      t: MonoTime
      lsh: PublishedArticles
      content: ptr string
    while true:
      (t, lsh, content) = await lshIn.popFirstwait
      if content in ptrTracker[]:
        warn "Clashing pointers found during processing lsh content."
        continue
      checkNil(lsh):
        checkNil(content):
          asyncSpawn checkAndAddArticle(t, lsh, content)
  except Exception as e: # If we quit we can catch defects too.
    if not e.isnil:
      echo e[]
    warn "lsh: lsh handler crashed."

proc lshHandler() =
  while true:
    waitFor asyncLshHandler()
    sleep(1000)
    warn "Restarting lsh..."



proc startLsh*() =
  setNil(lshIn):
    initLockDeque[(MonoTime, PublishedArticles, ptr string)]()
  setNil(lshOut):
    initLockTable[(MonoTime, PublishedArticles), bool]()
  setNil(ptrTracker):
    create(HashSet[pointer])
  ptrTracker[] = initHashSet[pointer]()
  createThread(lshThread, lshHandler)

when isMainModule:
  startLsh()
  let lsh = waitFor loadLS("mini")
  echo lsh.repr
  # var a = Article()
  # a.content = "test"
  # echo waitFor lsh.addArticle(a.content)
  # echo waitFor lsh.addArticle(a.content)
  # echo waitFor lsh.addArticle(a.content)
  # lsh[].remove("1")
  # echo id
