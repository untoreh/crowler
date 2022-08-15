import nimpy, os, nimdbx
import
    utils,
    quirks,
    cfg,
    types,
    translate_db

export translate_db
type PageCache {.borrow: `.`.} = LRUTrans
var pageCache*: ptr PageCache
let searchCache* = initLockLruCache[int64, string](1000)

proc initPageCache*(): PageCache =
    let dbpath = DATA_PATH / "sites" / WEBSITE_NAME / "page.db"
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    debug "cache: storing cache at {dbpath}"
    translate_db.DB_PATH[] = dbpath
    result = initLRUTrans()
    openDB(result)

proc initCache*() =
    try:
        if pageCache.isnil:
            let hc {.global.} = initPageCache()
            pageCache = hc.unsafeAddr
    except:
        let e = getCurrentException()[]
        qdebug "{e}"


proc `[]=`*[K, V](c: ptr PageCache, k: K, v: V) {.inline.} =
    c[][k] = v

proc `[]`*[K](c: ptr PageCache, k: K): string = c[][k]

# proc `get`*[K](c: ptr PageCache, k: K): string = c[].get(k)

