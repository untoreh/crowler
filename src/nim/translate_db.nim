import nimdbx
import os
import cfg
import translate_types
import strformat
import tables
import macros
import sugar
import hashes
import sets
import sequtils
import locks
import zstd / [compress, decompress]

import utils

{.experimental: "notnil".}

static: echo "loading translate_db"

type
    CollectionNotNil = ptr Collection not nil
    LRUTransObj = object
        db: nimdbx.Database.Database not nil
        coll: CollectionNotNil
        zstd_c: ptr ZSTD_CCtx
        zstd_d: ptr ZSTD_DCtx
    LRUTrans* = ptr LRUTransObj

converter derefCollection*(c: CollectionNotNil): Collection not nil =
    if not c.isnil:
        let v = cast[ptr Collection](c)[]
        if v.isnil:
            raise newException(ValueError, "Expected not nil collection")
        else:
            result = v
    else:
        raise newException(ValueError, "Couldn't convert collection.")

when defined(gcDestructors):
    proc `=destroy`(t: var LRUTransObj) =
        if not t.zstd_c.isnil:
            discard free_context(t.zstd_c)
        if not t.zstd_d.isnil:
            discard free_context(t.zstd_d)

var
    MAX_CACHE_ENTRIES = 16
    MAX_DB_SIZE* = 4096 * 1024 * 1024
    DB_PATH*: ptr string

const DEFAULT_DB_PATH = DATA_PATH / "translate.db"
DB_PATH = createShared(string)

# let transObj = new(LRUTrans)
# var trans*: LRUTrans = transOBj
var trans*: LRUTrans
var tLock*: Lock
initLock(tLock)
# Slations holds python objects, it must be unmanaged memory
var slations* {.threadvar.}: ptr Table[int64, string]

proc openDB*(t: var LRUTrans) {.gcsafe.} =
    if DB_PATH[].len == 0:
        DB_PATH[] = DEFAULT_DB_PATH
    t.db = openDatabase(DB_PATH[], maxFileSize = MAX_DB_SIZE)
    var c: Collection = t.db.openCollectionOrNil("slations", keytype = IntegerKeys)
    let cnn = cast[CollectionNotNil](createShared(Collection))
    if c.isnil:
        c = t.db.createCollection("slations", keytype = IntegerKeys)
        if c.isnil:
            raise newException(ValueError, "Cannot create collection")
        else:
            cnn[] = c
    else:
        cnn[] = c
    t.coll = cnn

proc initLRUTrans*(comp=true): LRUTrans =
    result = create(LRUTransObj)
    result.zstd_c = new_compress_context()
    result.zstd_d = new_decompress_context()

proc initSlations*(comp=true) {.gcsafe.} =
    if slations.isnil:
        slations = create(Table[int64, string])
        slations[] = initTable[int64, string]()

trans = initLRUTrans()
openDB(trans)

# macro doTx(pair: langPair, what: untyped): untyped =
#     result = quote do:
#         pairCollection(`pair`).inTransaction do (ct {.inject.}: CollectionTransaction):
#             `what`
#             ct.commit()

# macro doSnap(pair: langPair, what: untyped): untyped =
#     result = quote do:
#         pairCollection(`pair`).inSnapshot do (cs {.inject.}: CollectionSnapshot):
#             `what`

proc getImpl(t: LRUTrans, k: int64, throw: static bool): string =
    withLock(tLock):
        var o: seq[byte]
        t.coll.inSnapshot do (cs: CollectionSnapshot):
            # debug "nimdbx: looking for key {k}, {v}"
            o.add cs[k.asData].asByteSeq
        if len(o) > 0:
            result = cast[string](decompress(t.zstd_d, o))
            # debug "nimdbx: got key {k}, with {o.len} bytes"
        elif throw:
            raise newException(KeyError, "nimdbx: key not found")

proc getImpl[T: not int64](t: LRUTrans, k: T, throw: static bool): string =
    getImpl(t, hash(k).int64, throw)

proc `[]`*[T](t: LRUTrans, k: T): string = t.getImpl(k, false)
proc `get`*[T](t: LRUTrans, k: T): string = t.getImpl(k, true)

proc `[]=`*(t: LRUTrans, k: int64, v: string) {.gcsafe.} =
    withLock(tLock):
        # FIXME: Compress out of scope of the closure otherwise zstd has problems...
        let v = compress(t.zstd_c, v, cfg.ZSTD_COMPRESSION_LEVEL)
        debug "nimdbx: saving key {k}"
        t.coll.inTransaction do (ct: CollectionTransaction):
            {.cast(gcsafe).}:
                ct[k] = v
            ct.commit()
        debug "nimdbx: commited key {k}"

proc `[]=`*[K: not int64](t: LRUTrans, k: K, v: string) = t[hash(k).int64] = v

proc contains*(t: LRUTrans, k: int64): bool =
    var bs: seq[byte]
    withLock(tLock):
        t.coll.inSnapshot do (cs: CollectionSnapshot):
            bs = cs[k].asByteSeq
    return bs.len != 0

proc contains*[K: not int64](t: LRUTrans, k: K): bool = hash(k).int64 in t

proc clear*(t: LRUTrans) =
    withLock(tLock):
        var ks: seq[int64]
        t.coll.inSnapshot do (cs: CollectionSnapshot):
            var curs = makeCursor(cs)
            defer: curs.close
            ks = collect(for (k, _) in curs.pairs: k.asInt64)
        t.coll.inTransaction do (ct: CollectionTransaction):
            for k in ks:
                ct.del(k)
            ct.commit

proc delete*(t: LRUTrans) = removeDir(t.db.path)
proc path*(t: LRUTrans): string = t.db.path

proc save*(t: LRUTrans, c: Table[int64, string]) {.gcsafe.} =
    withLock(tLock):
        # compress outside the closure..
        debug "db: length of translations is {c.len}"
        var comp: seq[(int64, seq[byte])]
        for (k, v) in c.pairs:
            # Trying to compress empty values errors out
            if unlikely v == "":
                comp.add (k, static(newSeq[byte]()))
            else:
                debug "db: compressing key {k} of value {v}"
                comp.add (k, compress(t.zstd_c, v, level = ZSTD_COMPRESSION_LEVEL))
        debug "db: doing TX"
        t.coll.inTransaction do (ct: CollectionTransaction):
            for (k, v) in comp:
                debug "db: storing key {k}, with bytes {v.len}"
                {.cast(gcsafe).}:
                    ct[k] = v
            ct.commit()

proc save*[T: not int64](t: LRUTrans, c: Table[T, string]) {.gcsafe.} =
    t.save((for (k, v) in c.pairs(): (hash(k).int64, v)))

proc setFromDB*(pair: langPair, el: auto): (bool, int) =
    let
        txt = getText(el)
        k = hash((pair, txt)).int64

    # try temp cache before db
    if k in slations[]:
        setText(el, slations[][k])
        (true, txt.len)
    else:
        let t = trans[k]
        if t != "":
            setText(el, t)
            (true, txt.len)
        else:
            (false, txt.len)

proc saveToDB*(tr = trans, slations = slations,
        force = false) {.gcsafe.} =
    debug "slations: {slations[].len} - force: {force}"
    if slations[].len > 0 and (force or slations[].len > MAX_CACHE_ENTRIES):
        debug "db: saving to db"
        tr.save(slations[])
        debug "db: clearing slations ({slations[].len})"
        slations[].clear()
    debug "db: finish save"

template cursIter(c: Collection, what: untyped): untyped =
    let cs = c.beginSnapshot
    defer: cs.finish()
    var curs {.inject.} = makeCursor(cs)
    curs.first
    if curs.toBool():
        yield what
        while curs.next():
            yield what

iterator keys*(c: Collection not nil): auto =
    cursIter(c, curs.key)

iterator values*(c: Collection not nil, td=string): auto =
    cursIter(c,
             cast[string](decompress(trans.zstd_d,
                                     curs.value.asByteSeq)))
iterator items*(c: Collection not nil, td=string): auto =
    cursIter(c, (curs.key.asInt64,
                 cast[td](decompress(trans.zstd_d,
                                         curs.value.asByteSeq))))

proc del*(c: CollectionNotNil, k: int64) =
    withLock(tLock):
        c.inTransaction do (ct: CollectionTransaction):
            ct.del(k.asData)
            ct.commit()

proc del*[T: not int64](c: CollectionNotNil, k: T) = c.del(hash(k).int64)
proc del*[T](t: LRUTrans, k: T) = t.coll.del(k)

when isMainModule:
    import strutils, sequtils, sugar
    # let pair = (src: "en", trg: "it")
    # trans[(pair, "hello")] = "ohy"
    # let v = trans[(pair, "hello")]
    # echo v
    let png = @[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    echo trans[5664835887159656406]
