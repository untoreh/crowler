import std/[os, times, strformat, tables, macros, sugar, hashes, sets, sequtils,
    parseutils, strutils, locks]
import leveldb

import utils
import cfg

type
  LockDBObj = object
    lock: Lock
    handle: LevelDB
    ttl: Duration
  LockDB* = ptr LockDBObj
  ExpiredError = object of KeyError

proc `=destroy`*(db: var LockDBObj) =
  db.handle.close()
  deinitLock(db.lock)

const ttlKey = "ldb-ttl-key"
proc init*(_: typedesc[LockDB], path: string, ttl = initDuration(days = 100),
           ignoreErrors = false, lazyCompact = true): LockDB =
  result = create(LockDBObj)
  result.handle = leveldb.open(path,
                               # writeBufferSize = 64 * 1024 * 1024,
                               # maxFileSize = 32 * 1024 * 1024,
                               # cacheCapacity = 8 * 1024 * 1024
                               )
  if result.handle.get(ttlKey).isnone:
    if ttl == default(Duration):
      raise newException(ValueError, "TTL must be provided if the database doesn't already have one.")
    result.handle.put(ttlKey, $ttl.inSeconds)
    result.ttl = ttl
  elif ttl != default(Duration):
    template doraise() =
      if not ignoreErrors:
        raise newException(ValueError, "Provided ttl doesn't match database.")
    var mismatch = false
    try:
      let
        residentSecs = result.handle.get(ttlKey).get().parseInt
        residentTtl = initDuration(seconds = residentSecs)
      if ttl != default(Duration) and residentTtl != ttl:
        doraise()
      result.ttl = residentTtl
    except ValueError:
      logexc()
      warn "Corrupted ttl found in database, overwriting with {ttl}."
      result.handle.put(ttlKey, $ttl.inSeconds)
      result.ttl = ttl
  if lazyCompact:
    let lc_path = path / "last_compact.txt"

    let lc =
      if fileExists(lc_path): readFile(lc_path).parseInt.int64
      else: ttl.inSeconds
    if getTime().toUnix - lc > ttl.inSeconds:
      warn "Compacting database at {path}"
      result.compact()
      writeFile(lc_path, $getTime().toUnix)

proc isValid(ldb: LockDB, k: string, v: Option[string] = none[string](),
    nocheck: static[bool] = false, doraise: static[bool] = true): (bool, string) =
  if k == ttlKey:
    return (true, "")
  var v = v
  if v.isnone:
    v = ldb.handle.get(k)
  if v.issome:
    let spl = v.get().split(";", maxsplit = 1)
    when nocheck:
      result[1] =
        case spl.len:
          of 1: spl[0]
          of 2: spl[1]
          else: v.get()
    else:
      if spl.len == 2: # cache data is correct, check for staleness
        var ttlTime: int
        discard parseInt(spl[0], ttlTime)
        if getTime() - ttlTime.fromUnix <= ldb.ttl: # cache data is still valid
          result = (true, spl[1])
      else:
        when doraise:
          raise newException(ValueError, &"No creation date for key: {k}")
        else:
          result = (false, "")

proc getUnchecked*(ldb: LockDB, k: string): string =
  let fetched = isValid(ldb, k, nocheck = true)
  return fetched[1]

proc contains*[T](ldb: LockDB, k: T): bool =
  withLock(ldb.lock):
    return ldb.isValid(k)[0]

proc `[]=`*(ldb: LockDB, k: string, v: string) =
  withLock(ldb.lock):
    ldb.handle.put(k, $getTime().toUnix & ";" & v)

proc `get`*(ldb: LockDB, k: string): string =
  withLock(ldb.lock):
    let fetched = isValid(ldb, k)
    if fetched[0]:
      return fetched[1]
    else:
      raise newException(KeyError, &"Value not found or expired.")

template `[]`*(ldb: LockDB, k: string): string = ldb.get(k)

proc clear*(ldb: LockDB, keepttl = true) =
  withLock(ldb.lock):
    var ttlStr: string
    if keepttl:
      ttlStr.add ldb.handle.get(ttlKey).get()
    let batch = newBatch()
    for (k, v) in ldb.handle.iter:
      batch.delete(k)
    ldb.handle.write(batch)
    if keepttl:
      ldb.handle.put(ttlKey, ttlStr)

proc path*(ldb: LockDB): string = ldb.handle.path
proc delete*(ldb: LockDB, k: string) =
  withLock(ldb.lock):
    ldb.handle.delete(k)
template del*(ldb: LockDB, k: string) = ldb.delete(k)

proc compact*(ldb: LockDB, purgeOnError = false, batchsize = 1000) =
  ## Remove expired keys
  var v: string
  var batch = newBatch()
  defer: destroy(batch)
  var n = 0
  try:
    withLock(ldb.lock):
      for (k, v) in ldb.handle.iter():
        if not isValid(ldb, k, some(v), doraise = false)[0]:
          batch.delete(k)
          n.inc
          if n > batchsize:
            ldb.handle.write(batch)
            clear(batch)
            n = 0
            GC_runOrc()
      if n > 0:
        ldb.handle.write(batch)
  except ValueError:
    logexc()
    if purgeOnError:
      ldb.clear()

proc put*[T](ldb: LockDB, vals: T) =
  var batch = newBatch()
  defer: destroy(batch)
  for (k, v) in vals:
    batch.put(k, $getTime().toUnix & ";" & v)
  ldb.handle.write(batch)

proc toUint32*(s: string): uint32 =
  case s.len:
    of 4: copyMem(result.addr, s[0].unsafeAddr, 4)
    of 0: result = 0
    else:
      raise newException(ValueError, "Wrong string length for conversion to uint.")

proc toString*(u: uint32): string =
  result = newString(4)
  copyMem(result[0].addr, u.unsafeAddr, 4)

# let db = init(LockDB, config.websitePath / "test.db")
