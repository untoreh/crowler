import nimpy, std/[os, strutils, hashes], nimdbx
import
  utils,
  quirks,
  cfg,
  types,
  translate_types,
  translate_db

export translate_db
type PageCache {.borrow: `.`.} = LRUTrans
var pageCache*: ptr PageCache
let searchCache* = initLockLruCache[int64, string](32)

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

proc suffixPath*(relpath: string): string =
  var relpath = relpath
  relpath.removeSuffix("/")
  if relpath == "":
    "index.html"
  elif relpath.splitFile.ext == "":
    relpath & ".html"
  else: relpath

proc fp*(relpath: string): string =
  ## Full file path
  # NOTE: Only Unix paths make sense! because `/` operator would output `\` on windows
  SITE_PATH / relpath.suffixPath()

proc deletePage*(relpath: string) {.gcsafe.} =
  logall "cache: deleting page {relpath}"
  let
    sfx = relpath.suffixPath()
    fpath = SITE_PATH / sfx
    fkey = fpath.hash
  pageCache[].del(fkey)
  pageCache[].del(hash(SITE_PATH / "amp" / sfx))
  for lang in TLangsCodes:
    pageCache[].del(hash(SITE_PATH / "amp" / lang / sfx))
    pageCache[].del(hash(SITE_PATH / lang / sfx))

# proc `get`*[K](c: ptr PageCache, k: K): string = c[].get(k)

