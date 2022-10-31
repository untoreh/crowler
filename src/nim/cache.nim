import nimpy, std/[os, strutils, hashes, times, parseutils], nimdbx
import
  utils,
  quirks,
  cfg,
  types,
  translate_types,
  translate_db

export translate_db
type DataCache {.borrow: `.`.} = LRUTrans

const pageCacheTtl = initDuration(days = 1)
let searchCache* = initLockLruCache[int64, string](32)
var pageCache*: ptr DataCache
var imgCache*: ptr DataCache

proc init*(cache: var DataCache, name: string) =
  let dbpath = DATA_PATH / "sites" / WEBSITE_NAME / name
  translate_db.MAX_DB_SIZE = 40 * 1024 * 1024 * 1024
  debug "cache: storing cache at {dbpath}"
  translate_db.DB_PATH[] = dbpath
  cache = initLRUTrans()
  openDB(cache)

proc initCache*() =
  try:
    if pageCache.isnil:
      pageCache = create(DataCache)
      init(pageCache[], "page")
    if imgCache.isnil:
      imgCache = create(DataCache)
      init(imgCache[], "image")
  except:
    logexc()
    qdebug "cache: failed init"

template getOrCache*(k: int64 | string, code: untyped): string =
  template process(): string =
    page = code
    pageCache[k] = $getTime().toUnix & ";" & page
    move page
  block:
    var n: int
    if k in pageCache[]:
      let spl = pageCache[k].split(";", maxsplit = 1)
      if spl.len == 2: # cache data is correct, check for staleness
        let ttlTime = parseInt(spl[0], n).fromUnix
        if getTime() - ttlTime > pageCacheTtl: # cache data is stale
          process()
        else: # cache data is still valid
          spl[1]
      else: # cache data is corrupted, purge and re-process
        process()
    else: # cache miss
      process()

proc `[]=`*[K, V](c: ptr DataCache, k: K, v: V) {.inline.} =
  c[][k] = v

proc `[]`*[K](c: ptr DataCache, k: K): string = c[][k]

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

# proc `get`*[K](c: ptr DataCache, k: K): string = c[].get(k)
