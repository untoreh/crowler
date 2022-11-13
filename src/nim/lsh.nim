import std/[importutils, strutils, marshal, tables, sets, algorithm, os, monotimes, strformat], chronos,
    minhash {.all.}

import cfg, types, utils, sharedqueue, locktpl
lockedSet(HashSet)
privateAccess(LocalitySensitive)
export minhash
{.experimental: "notnil".}

type
  PublishedArticles* = LocalitySensitive[uint64]
var lshThread: Thread[void]
var futs {.threadvar.}: seq[Future[void]]

proc getLSPath(topic: string): string =
  DATA_PATH / "sites" / WEBSITE_NAME / "topics" / topic / "lsh"

proc init*(_: typedesc[PublishedArticles]): PublishedArticles =
  let hasher = initMinHasher[uint64](64)
  # very small band width => always find duplicates
  result = initLocalitySensitive[uint64](hasher, 16)

proc saveLSImpl(topic: string, lsh: PublishedArticles) {.async.} =
  let path = getLSPath(topic)
  createDir(path)
  let lshJson = $$lsh
  let comp = compress(lshJson)
  await writeFileAsync(path / "lsh.json.zst", comp)

proc saveLS*(topic: string, lsh: sink PublishedArticles) {.async.} =
  await saveLSImpl(topic, lsh)

proc toLsh(data: string): PublishedArticles =
  result = to[PublishedArticles](data)
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
          let ls = ($j[1]).toLsh
          await saveLS(topic, ls)

proc loadLS*(topic: string): Future[PublishedArticles] {.async.} =
  logall "lsh: loading topic {topic}"
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
    try:
      result = data.toLsh
    except Exception as e:
      warn "Couldn't load LSH for topic {topic}, trying fix."
      try:
        await fixLS(topic, data)
      except Exception:
        warn "Couldn't apply fix for lsh."
        raise e
  else:
    return init(PublishedArticles)

type
  LshQuery = object
    id: MonoTime
    lsh: ptr PublishedArticles
    content: ptr string

# these should be generalized since it's the same from `imageflow_server`
var lshIn: AsyncPColl[ptr LshQuery]
var lshOut: AsyncTable[ptr LshQuery, bool]

proc addArticle*(lsh: PublishedArticles, content: ptr string): Future[bool] {.async.} =
  var q: LshQuery
  q.id = getMonoTime()
  q.lsh = lsh.unsafeAddr
  q.content = content
  lshIn.add q.addr
  return await lshOut.pop(q.addr)

# {.experimental: "strictnotnil".}
proc checkAndAddArticle(q: ptr LshQuery) {.async.} =
  try:
    checkNil(q.lsh)
    checkNil(q.content)
    if not isDuplicate(q.lsh[], q.content[]):
      let id = $(len(q.lsh.fingerprints) + 1)
      let cnt = deepcopy(q.content[])
      q.lsh[].add(cnt, id)
      lshOut[q] = true
    else:
      lshOut[q] = false
  except Exception as e:
    logexc()
    lshOut[q] = false
    warn "lsh: error adding article."

proc asyncLshHandler() {.async.} =
  try:
    while true:
      let q = await lshIn.pop
      clearFuts(futs)
      checkNil(q):
        futs.add checkAndAddArticle(q)
  except Exception as e: # If we quit we can catch defects too.
    logexc()
    warn "lsh: lsh handler crashed."

proc lshHandler() =
  while true:
    waitFor asyncLshHandler()
    sleep(1000)
    warn "Restarting lsh..."

proc startLsh*() =
  setNil(lshIn):
    newAsyncPColl[ptr LshQuery]()
  setNil(lshOut):
    newAsyncTable[ptr LshQuery, bool]()
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
