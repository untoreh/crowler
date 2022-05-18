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

proc initPageCache*(): PageCache =
    let dbpath = DATA_PATH / (WEBSITE_DOMAIN & ".page.db")
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    debug "cache: storing cache at {dbpath}"
    translate_db.DB_PATH[] = dbpath
    result = initLRUTrans()
    openDB(result)

proc initCache*() {.raises: []} =
    try:
        if pageCache.isnil:
            let hc {.global.} = initPageCache()
            pageCache = hc.unsafeAddr
    except:
        qdebug "{getCurrentExceptionMsg()}"


proc `[]=`*[K, V](c: ptr PageCache, k: K, v: V) {.inline.} =
    c[][k] = v

# proc `[]=`*[K, V](c: ptr PageCache, k: K, v: V) {.inline.} =
#     c[][k] = v
