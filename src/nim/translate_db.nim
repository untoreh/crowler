import nimdbx
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
    trNode = tuple[prev: int, value: string, next: int]
    CollectionNotNil = Collection not nil
    LRUTransObj = object
        db: nimdbx.Database.Database not nil
        coll: Collection not nil
        zstd_c: ptr ZSTD_CCtx
        zstd_d: ptr ZSTD_DCtx
    LRUTrans* = ptr LRUTransObj

when defined(gcDestructors):
    proc `=destroy`(t: var LRUTransObj) =
        if not t.zstd_c.isnil:
            discard free_context(t.zstd_c)
        if not t.zstd_d.isnil:
            discard free_context(t.zstd_d)

const
    MAX_CACHE_ENTRIES = 16
    MAX_DB_SIZE = 4096 * 1024 * 1024

proc initLRUTrans(): LRUTrans =
    result = createShared(LRUTransObj)
    result.zstd_c = new_compress_context()
    result.zstd_d = new_decompress_context()

# let transObj = new(LRUTrans)
# var trans*: LRUTrans = transOBj
var trans* = initLRUTrans()
var tLock*: Lock
initLock(tLock)
var slations* {.threadvar.}: ptr Table[int64, string]

proc transOpenDB(t = trans) =
    t.db = openDatabase(cfg.DB_PATH, maxFileSize = MAX_DB_SIZE)
    var c: Collection = t.db.openCollectionOrNil("slations", keytype = IntegerKeys)
    var cnn: Collection not nil
    if c.isnil:
        c = trans.db.createCollection("slations", keytype = IntegerKeys)
        if c.isnil:
            raise newException(ValueError, "Cannot create collection")
        else:
            cnn = c
    else:
        cnn = c
    t.coll = cnn

proc initTrans*() =
    if slations.isnil:
        slations = create(Table[int64, string])
        slations[] = initTable[int64, string]()

transOpenDB()

macro doTx(pair: langPair, what: untyped): untyped =
    result = quote do:
        pairCollection(`pair`).inTransaction do (ct {.inject.}: CollectionTransaction):
            `what`
            ct.commit()

macro doSnap(pair: langPair, what: untyped): untyped =
    result = quote do:
        pairCollection(`pair`).inSnapshot do (cs {.inject.}: CollectionSnapshot):
            `what`

proc `[]`*(t: LRUTrans, k: int64): string =
    withLock(tLock):
        var o: seq[byte]
        t.coll.inSnapshot do (cs: CollectionSnapshot):
            o.add cs[k].asByteSeq
        if len(o) > 0:
            result = cast[string](decompress(t.zstd_d, o))

proc `[]`*(t: LRUTrans, k: (langPair, string)): string = t[hash(k).int64]

proc `[]=`*(t: LRUTrans, k: int64, v: string) =
    withLock(tLock):
        # FIXME: Compress out of scope of the closure otherwise zstd has problems...
        let v = compress(t.zstd_c, v, cfg.ZSTD_COMPRESSION_LEVEL)
        t.coll.inTransaction do (ct: CollectionTransaction):
            ct[k] = v
            ct.commit()

proc `[]=`*(t: LRUTrans, k: (langPair, string), v: string) = t[hash(k).int64] = v

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

proc save*[T](t: LRUTrans, c: Table[T, string]) =
    withLock(tLock):
        # compress outside the closure..
        var comp: seq[(T, seq[byte])]
        for (k, v) in c.pairs:
            comp.add (k, compress(t.zstd_c, v, level=ZSTD_COMPRESSION_LEVEL))
        t.coll.inTransaction do (ct: CollectionTransaction):
            for (k, v) in comp:
                ct[k.int64] = v
            ct.commit()

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
        force = false) =
    {.cast(gcsafe).}:
        debug "slations: {slations[].len} - force: {force}"
        if slations[].len > 0 and (force or slations[].len > MAX_CACHE_ENTRIES):
            debug "db: saving to db"
            tr.save(slations[])
            debug "db: clearing slations ({slations[].len})"
            slations[].clear()
        debug "db: finish save"

# when isMainModule:
#     let pair = (src: "en", trg: "it")
#     trans[(pair, "hello")] = "hehe"
#     let v = trans[(pair, "hello")]
