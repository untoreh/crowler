import nimpy, std/[os, strutils, hashes, times, parseutils]
import
  utils,
  quirks,
  cfg,
  types,
  translate_types,
  server_types,
  data

export data

const pageCacheTtl = initDuration(days = 1)
let searchCache* = initLockLruCache[string, string](32)
var pageCache*: LockDB
var imgCache*: LockDB

proc initCache*(doclear=false, comp=false) =
  try:
    setNil(pageCache):
      init(LockDB, config.websitePath / "page", initDuration(hours = 8))
    setNil(imgCache):
      init(LockDB, config.websitePath / "image", initDuration(days = 50))
    if doclear:
      pageCache.clear()
      imgCache.clear()
    elif comp:
      pageCache.compact()
      imgCache.compact()
  except:
    logexc()
    qdebug "cache: failed init"

template getOrCache*(k: int64 | string, code: untyped): string =
  template process(): string =
    page = code
    pageCache[k] = page
    move page
  block:
    let v = pageCache.getUnchecked(k)
    if len(v) > 0:
      v
    else: # cache miss
      process()

proc suffixPath*(relpath: string): string =
  var relpath = relpath
  relpath.removeSuffix("/")
  if relpath == "":
    "index.html"
  else:
    let split = relpath.splitFile
    if split.ext == "":
      if split.name == "": relpath & "index.html"
      else: relpath & ".html"
    else: relpath

proc fp*(relpath: string): string =
  ## Full file path
  # NOTE: Only Unix paths make sense! because `/` operator would output `\` on windows
  SITE_PATH / relpath.suffixPath()

proc cacheKey*(capts: UriCaptures): string {.inline.} =
  var path = capts.joinNotEmpty
  if not path.startsWith("/"):
    path = "/" & path
  return path.fp

proc cacheKey*(relPath: string): string =
  let capts = uriTuple(relPath)
  return cacheKey(capts)

proc deletePage*(capts: UriCaptures) {.gcsafe.} =
  logall "cache: deleting page {capts}"
  var capts = capts
  let k = capts.cacheKey
  template doDel() =
    capts.amp = ""
    pageCache.delete(capts.cacheKey)
    capts.amp = "/amp"
    pageCache.delete(capts.cacheKey)

  doDel()

  for lang in TLangsCodes:
    capts.lang = lang
    doDel()

proc deletePage*(s: string) = deletePage(uriTuple(s))

# proc deletePage*(relpath: string) {.gcsafe.} =
#   logall "cache: deleting page {relpath}"
#   let
#     sfx = relpath.suffixPath()
#     fpath = SITE_PATH / sfx
#     fkey = fpath.hash
#   pageCache[].del(fkey)
#   pageCache[].del(hash(SITE_PATH / "amp" / sfx))
#   for lang in TLangsCodes:
#     pageCache[].del(hash(SITE_PATH / "amp" / lang / sfx))
#     pageCache[].del(hash(SITE_PATH / lang / sfx))

# proc `get`*[K](c: ptr DataCache, k: K): string = c[].get(k)
