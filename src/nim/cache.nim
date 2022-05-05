import nimpy, os, nimdbx
import
    quirks,
    cfg,
    types,
    translate_db

type HtmlCache {.borrow: `.`.} = LRUTrans
var htmlCache*: ptr HtmlCache

proc initHtmlCache*(): HtmlCache =
    translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
    translate_db.DB_PATH[] = DATA_PATH / "html.db"
    result = initLRUTrans()
    openDB(result)

proc `[]=`*[K, V](c: ptr HtmlCache, k: K, v: V) {.inline.} =
    c[][k] = v
