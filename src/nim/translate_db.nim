import nimdbx
import cfg
import translate_types
import strformat
import tables
import macros
import sugar
import hashes
import sets
import frosty/streams
import utils
import locks

{.experimental: "notnil".}

type
    trNode = tuple[prev: int, value: string, next: int]
    CollectionNotNil = Collection not nil
    LRUTransObj = object
        db: nimdbx.Database.Database not nil
        coll: Collection not nil
    LRUTrans* = ptr LRUTransObj

const
    MAX_CACHE_ENTRIES = 1024
    MAX_DB_SIZE = 4096 * 1024 * 1024


proc initLRUTrans(): LRUTrans = result = new(LRUTransObj)[].addr

# let transObj = new(LRUTrans)
# var trans*: LRUTrans = transOBj
var trans* = initLRUTrans()
var tLock*: Lock
initLock(tLock)
var slations* {.threadvar.}: ref Table[int, string]

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
        new(slations)

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

proc `[]`*(t: LRUTrans, k: (langPair, string)): string =
    withLock(tLock):
        var o: string
        t.coll.inSnapshot do (cs: CollectionSnapshot):
            o = cs[hash(k).int64].asString
        return o

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

proc save*(t: LRUTrans, c: ref Table) =
    withLock(tLock):
        t.coll.inTransaction do (ct: CollectionTransaction):
            for (k, v) in c.pairs():
                ct[k.int64] = v
            ct.commit()

proc setFromDB*(pair: langPair, el: auto): (bool, int) =
    let
        txt = getText(el)
        t = trans[(pair, txt)]
    if t != "":
        setText(el, t)
        (true, txt.len)
    else:
        (false, txt.len)

proc saveToDB*(tr = trans, slations = slations,
        force = false) =
    {.cast(gcsafe).}:
        if slations.len > 0:
            debug "db: saving to db"
            tr.save(slations)
            debug "db: clearing slations ({slations.len})"
            slations.clear()
