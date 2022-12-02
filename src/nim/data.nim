import std/[os, times, strformat, tables, macros, sugar, hashes, sets, sequtils, parseutils, strutils, locks]
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
proc init*(_: typedesc[LockDB], path: string, ttl = initDuration(days = 100)): LockDB =
  result = create(LockDBObj)
  result.handle = leveldb.open(path)
  if result.handle.get(ttlKey).isnone:
    if ttl == default(Duration):
        raise newException(ValueError, "TTL must be provided if the database doesn't already have one.")
    result.handle.put(ttlKey, $ttl.inSeconds)
    result.ttl = ttl
  elif ttl != default(Duration):
    let
      residentSecs = result.handle.get(ttlKey).get().parseInt
      residentTtl = initDuration(seconds = residentSecs)
    if ttl != default(Duration) and residentTtl != ttl:
      raise newException(ValueError, "Provided ttl doesn't match database.")
    result.ttl = residentTtl

proc isValid(ldb: LockDB, k: string, v: Option[string] = none[string](), nocheck: static[bool] = false): (bool, string) =
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
        raise newException(ValueError, &"No creation date for key: {k}")

proc getUnchecked*(ldb: LockDB, k: string): string =
  let fetched = isValid(ldb, k, nocheck = true)
  return fetched[1]

proc contains*[T](ldb: LockDB, k: T): bool =
  withLock(ldb.lock):
    ldb.isValid(k)[0]

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

proc clear*(ldb: LockDB) =
  withLock(ldb.lock):
    let batch = newBatch()
    for (k, v) in ldb.handle.iter:
      batch.delete(k)
    ldb.handle.write(batch)

proc path*(ldb: LockDB): string = ldb.handle.path
proc delete*(ldb: LockDB, k: string) =
  withLock(ldb.lock):
    ldb.handle.delete(k)
template del*(ldb: LockDB, k: string) = ldb.delete(k)

proc compact*(ldb: LockDB) =
  ## Remove expired keys
  var v: string
  var batch = newBatch()
  withLock(ldb.lock):
    for (k, v) in ldb.handle.iter():
      if not isValid(ldb, k, some(v))[0]:
        batch.delete(k)
    ldb.handle.write(batch)

proc put*[T](ldb: LockDB, vals: T) =
  var batch = newBatch()
  for (k, v) in vals:
    batch.put(k, v)
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

# let db = init(LockDB, WEBSITE_PATH / "test.db")
