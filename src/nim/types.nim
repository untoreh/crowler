import
    times, nimpy, os, strutils, strformat,
    nimpy / py_lib,
    std / osproc,
    sets, locks,
    sharedtables, lrucache
import pyutils
export pyutils
# Generics
proc put*[T, K, V](t: T, k: K, v: V): V = (t[k] = v; v)

type
    TS = enum
        str,
        time
    # TimeString = object
    #     case kind: TS
    #     of str: str: string
    #     of time: time: Time

    Article* = ref object of RootObj
        title*: string
        desc*: string
        content*: string
        author*: string
        pubDate*: Time
        pubTime*: Time
        imageUrl*: string
        icon*: string
        url*: string
        slug*: string
        # lang*: string # NOTE: we assume articles are always in SLang (english)
        topic*: string
        page*: int ## what page does this article belong to
        tags*: seq[string]
        py*: PyObject

var emptyArt* {.threadvar.}: Article
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

proc initArticle*(data: PyObject, pagenum: int): Article =
    try:
        let a = new(Article)
        a.title = pyget(data, "title")
        a.desc = pyget(data, "desc")
        a.content = pyget(data, "content")
        a.author = pyget(data, "author")
        a.pubDate = pydate(data.pyget("pubDate", PyNone), getTime())
        a.pubTime = pydate(data.pyget("pubTime", PyNone), default(Time))
        a.imageUrl = pyget(data, "imageUrl")
        a.icon = pyget(data, "icon")
        a.url = pyget(data, "url")
        a.slug = pyget(data, "slug")
        # a.lang = pyget(data, "lang")
        a.topic = pyget(data, "topic")
        a.page = pyget(data, "page", pagenum)
        a.slug = pyget(data, "slug")
        a.tags = pyget(data, "tags", emptyseq)
        a.py = data
        a
    except ValueError as e:
        raise newException(ValueError, fmt"Couldn't create Article from {data}, {e.msg}")

proc default*(_: typedesc[Article]): Article = initArticle(PyNone, 0)

proc initTypes*() =
    withPyLock:
        try:
            emptyArt = default(Article)
        except:
            try:
                echo fmt"types: failed to initialize default article {getCurrentExceptionMsg()}"
                quit()
            except: quit()

import
    locktpl,
    tables


proc get*[K, V](t: Table[K, V], k: K): V = t[k] # the table module doesn't have this

lockedStore(Table)
lockedStore(LruCache)

export tables,
       locks

proc `[]`*[K, V](t: var SharedTable[K, V], k: K): V = t.mget(k)
proc `get`*[K, V](t: var SharedTable[K, V], k: K): V = t.mget(k)
proc `put`*[K, V](t: var SharedTable[K, V], k: K, v: V): V =
    t[k] = v
    return v

# Shared hashset
type SharedHashSet*[T] = ref object
    data: HashSet[T]
    lock: Lock

proc init*[T](s: SharedHashSet[T]) =
    s.data = initHashSet[T]()
    initLock(s.lock)

proc contains*[T](d: SharedHashSet[T], v: T): bool =
    withLock(d.lock):
        result = v in d.data
proc incl*[T](d: SharedHashSet[T], v: T) =
    withLock(d.lock):
        d.data.incl(v)
proc excl*[T](d: SharedHashSet[T], v: T) =
    withLock(d.lock):
        d.data.excl(v)

# PathLocker
type PathLock* = LockTable[string, ref Lock]
var locksBuffer* {.threadvar.}: seq[ref Lock]

proc initPathLock*(): PathLock =
    initLockTable[string, ref Lock]()

proc addLocks*() =
    for _ in 0..<100:
        locksBuffer.add new(Lock)

proc get*(b: var seq[ref Lock]): ref Lock =
    try:
        return b.pop()
    except:
        addLocks()
        return b.pop()

proc contains*(pl: PathLock, k: string): bool = k in pl

proc acquireOrWait*(pl: PathLock, k: string): bool =
    try:
        # waited
        withLock(pl[k][]):
            discard
        result = false
    except KeyError:
        # acquired
        pl.put(k, locksBuffer.get)[].acquire()
        result = true

proc release*(pl: PathLock, k: string) =
    try:
        pl[k][].release()
    except KeyError: discard

# Bytes handling
# const MAX_FILE_SIZE = 100 * 1024 * 1024
# proc readBytes(f: string): seq[byte] =
#     readBytes(f, )
