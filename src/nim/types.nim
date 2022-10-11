import
  times, nimpy, os, strutils, strformat,
  nimpy / py_lib,
  std / osproc,
  sets, locks,
  lrucache,
  chronos,
  nre

import pyutils
export pyutils

# Generics
proc put*[T, K, V](t: T, k: K, v: V): V = (t[k] = v; v)


type
  TS = enum
    str,
    time
  Article* = ref object of RootObj
    title*: string
    desc*: string
    content*: string
    author*: string
    pubDate*: Time
    pubTime*: Time
    imageUrl*: string
    imageTitle*: string
    imageOrigin*: string
    icon*: string
    url*: string
    slug*: string
    # lang*: string # NOTE: we assume articles are always in SLang (english)
    topic*: string
    page*: int ## what page does this article belong to
    tags*: seq[string]
    py*: PyObject

var emptyArt*: ptr Article
const emptyseq*: seq[string] = @[]

proc `$`*(a: Article): string =
  "\ptitle: " &
      a.title &
      "\pdate: " &
      $a.pubDate &
      "\purl: " &
      a.url

proc plural(str: string, count: int): string =
  if count == 1:
    return str
  else:
    return str & "s"

proc agoDateStr*(date: DateTime): string =
  ## This function can't be used with static file generators :(
  let ago = " ago"
  let parts = (now() - date).toParts()
  var c: int
  if parts[Weeks] >= 52:
    c = parts[Weeks].div(52).int()
    return $c & " year".plural(c) & ago
  elif parts[Days] >= 30:
    c = parts[Days].div(30).int()
    return $c & " month".plural(c) & ago
  elif parts[Minutes] >= 24 * 60:
    c = parts[Hours].div(24 * 60).int()
    return $c & " day".plural(c) & ago
  elif parts[Minutes] >= 60:
    c = parts[Hours].div(60).int()
    return $c & " hour".plural(c) & ago
  elif parts[Seconds] >= 60:
    c = parts[Seconds].div(60).int()
    return $c & " minute".plural(c) & ago
  elif parts[Seconds] >= 1:
    c = parts[Seconds].div(60).int()
    return $c & " second" & ago
  else:
    return "just now"

type
  topicData* = enum
    articles = "articles",
    feeds = "feeds",
    done = "done"
    pages = "pages"

proc initArticle*(data: PyObject, pagenum = -1): Article =
  try:
    let a = new(Article)
    a.title = pyget(data, "title")
    a.desc = pyget(data, "desc")
    a.content = pyget(data, "content")
    a.author = pyget(data, "author")
    a.pubDate = pydate(data.pyget("pubDate", PyNone), getTime())
    a.pubTime = pydate(data.pyget("pubTime", PyNone), default(Time))
    a.icon = pyget(data, "icon")
    a.url = pyget(data, "url")
    a.slug = pyget(data, "slug")
    a.imageUrl = pyget(data, "imageUrl")
    a.imageTitle = pyget(data, "imageTitle", a.desc)
    a.imageOrigin = pyget(data, "imageOrigin", a.url)
    # a.lang = pyget(data, "lang")
    a.topic = pyget(data, "topic")
    a.page = pyget(data, "page", pagenum)
    a.tags = pyget(data, "tags", emptyseq)
    a.py = data
    a
  except ValueError as e:
    raise newException(ValueError, fmt"Couldn't create Article from {data}, {e.msg}")

proc default*(_: typedesc[Article]): Article = initArticle(PyNone)

proc initTypes*() =
  try:
    pygil.globalAcquire()
    if emptyArt.isnil():
      emptyArt = create(Article)
    emptyArt[] = default(Article)
  except:
    try:
      let e = getCurrentException()[]
      stdout.write fmt"types: failed to initialize default article {e}\n"
      quit()
    except:
      echo "failed init types"
      quit()
  finally:
    pygil.release()

import
  locktpl,
  tables


proc get*[K, V](t: OrderedTable[K, V] | Table[K, V], k: K): V = t[
    k] # the table module doesn't have this

# lockedStore(Table) # defined in utils
lockedStore(LruCache)


export tables,
       locks

# Bytes handling
# const MAX_FILE_SIZE = 100 * 1024 * 1024
# proc readBytes(f: string): seq[byte] =
#     readBytes(f, )
