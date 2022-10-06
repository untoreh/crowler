import std/[importutils, strutils, marshal, tables, algorithm, os, monotimes, strformat], chronos,
    minhash {.all.}

import cfg, types, utils
privateAccess(LocalitySensitive)
export minhash
{.experimental: "notnil".}

type
  PublishedArticlesObj = LocalitySensitive[uint64]
  PublishedArticles* = ptr PublishedArticlesObj
var lshThread: Thread[void]

proc `destroy=`*(lsh: PublishedArticles) =
    if not lsh.isnil:
      reset(lsh[])
      dealloc(lsh)

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
  await writeFileAsync(path / "lsh.json.zst", compress(lshJson))

proc saveLS*(topic: string, lsh: PublishedArticles) {.async.} =
  if lsh.isnil:
    raise newException(ValueError, "lsh can't be nil.")
  await saveLSImpl(topic, lsh[])

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
var lshIn*: LockDeque[(MonoTime, PublishedArticles, string)]
var lshOut*: LockTable[(MonoTime, PublishedArticles), bool]

proc addArticle*(lsh: PublishedArticles, content: string): Future[bool] {.async.} =
  let t = getMonoTime()
  lshIn.addLast (t, lsh, content)
  return await lshOut.popWait((t, lsh))

proc checkAndAddArticle(t: MonoTime, lsh: PublishedArticles, content: string) {.async.} =
  let k = (t, lsh)
  try:
    if not isDuplicate(lsh[], content):
      let id = $(len(lsh.fingerprints) + 1)
      lsh[].add(content, id)
      lshOut[k] = true
    else:
      lshOut[k] = false
  except CatchableError as e:
    warn "lsh: error adding article {e[]}."
    lshOut[k] = false

proc asyncLshHandler() {.async.} =
  try:
    while true:
      let (t, lsh, content) = await lshIn.popFirstwait
      checkNil(lsh):
        asyncSpawn checkAndAddArticle(t, lsh, content)
  except: # If we quit we can catch defects too.
    let e = getCurrentException()[]
    warn "lsh: lsh handler crashed. {e}"
    quit!()

proc lshHandler() = waitFor asyncLshHandler()

proc startLsh*() =
  setNil(lshIn):
    initLockDeque[(MonoTime, PublishedArticles, string)]()
  setNil(lshOut):
    initLockTable[(MonoTime, PublishedArticles), bool]()
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
