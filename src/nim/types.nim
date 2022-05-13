import
    times, nimpy, os, strutils, strformat,
    nimpy / py_lib,
    std / osproc,
    sets, locks, sequtils,
    sharedtables, lrucache

# Generics
proc put*[T, K, V](t: T, k: K, v: V): V = (t[k] = v; v)

proc setPyLib() =
    var (pylibpath, success) = execCmdEx("python3 -c 'import find_libpython; print(find_libpython.find_libpython())'")
    if success != 0:
        let (_, pipsuccess) = execCmdEx("pip3 install find_libpython")
        assert pipsuccess == 0
    (pylibpath, success) = execCmdEx("python3 -c 'import find_libpython; print(find_libpython.find_libpython())'")
    assert success == 0
    pylibpath.stripLineEnd
    pyInitLibPath pylibpath

# setPyLib()
let machinery = pyImport("importlib.machinery")
proc relpyImport*(relpath: string): PyObject =
    let abspath = os.expandFilename(relpath & ".py")
    let name = abspath.splitFile[1]
    let loader = machinery.SourceFileLoader(name, abspath)
    return loader.load_module(name)

# we have to load the config before utils, otherwise the module is "partially initialized"
let pycfg* = relpyImport("../py/config")
# let pylog* = relpyImport("../py/log")
let ut* = relpyImport("../py/utils")

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
        imageUrl*: string
        icon*: string
        url*: string
        slug*: string
        lang*: string
        topic*: string
        page*: int ## what page does this article belong to
        tags*: seq[string]
        py*: PyObject

const emptyseq*: seq[string] = @[]

# https://github.com/yglukhov/nimpy/issues/164
let
    builtins = pyBuiltinsModule()
    za = pyimport("zarr")
    PyBoolClass = builtins.True.getattr("__class__")
    PyNoneClass = builtins.None.getattr("__class__")
    PyDateTimeClass = pyimport("datetime").datetime
    PyStrClass = builtins.str.getattr("__class__")
    PyDictClass = builtins.dict.getattr("__class__")
    PyZArray = za.getAttr("Array")
    PyNone* = builtins.None
    pySlice = builtins.slice

var emptyArt* {.threadvar.}: Article

proc pyclass(py: PyObject): PyObject {.inline.} =
    builtins.type(py)

proc pytype*(py: PyObject): string =
    py.pyclass.getattr("__name__").to(string)

proc pyisbool*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyBoolClass).to(bool)

proc pyisnone*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyNoneClass).to(bool)

proc pyisdatetime*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyDateTimeClass).to(bool)

proc pyisstr*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyStrClass).to(bool)

proc pyiszarray*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyZArray).to(bool)

proc `$`*(a: Article): string =
    "\ptitle: " &
        a.title &
        "\pdate: " &
        $a.pubDate &
        "\purl: " &
        a.url

const ymdFormat* = "yyyy-MM-dd"
const isoFormat* = "yyyy-MM-dd'T'HH:mm:ss"

proc pydate*(py: PyObject, default = getTime()): Time =
    if pyisnone(py):
        return default
    elif pyisstr(py):
        let s = py.to(string)
        if s == "":
            return default
        else:
            try:
                return parseTime(py.to(string), isoFormat, utc())
            except TimeParseError:
                try:
                    return parseTime(py.to(string), ymdFormat, utc())
                except TimeParseError:
                    return default
    elif pyisdatetime(py):
        return py.timestamp().to(float).fromUnixFloat()
    else:
        return default

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


var e: ref ValueError
new(e)
e.msg = "All python objects were None."

proc pysome*(pys: varargs[PyObject], default = new(PyObject)): PyObject =
    for py in pys:
        if pyisnone(py):
            continue
        else:
            return py
    raise e

proc len*(py: PyObject): int =
    builtins.len(py).to(int)

proc isa*(py: PyObject, tp: PyObject): bool =
    builtins.isinstance(py, tp).to(bool)

proc pyget*[T](py: PyObject, k: string, def: T = ""): T =
    try:
        let v = py.callMethod("get", k)
        if pyisnone(v):
            return def
        else:
            return v.to(T)
    except:
        if pyisnone(py):
            return def
        else:
            return py.to(T)

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
        a.pubDate = pydate(data.pyget("pubDate", PyNone), getTIme())
        a.imageUrl = pyget(data, "imageUrl")
        a.icon = pyget(data, "icon")
        a.url = pyget(data, "url")
        a.slug = pyget(data, "slug")
        a.lang = pyget(data, "lang")
        a.topic = pyget(data, "topic")
        a.page = pyget(data, "page", pagenum)
        a.slug = pyget(data, "slug")
        a.tags = pyget(data, "tags", emptyseq)
        a.py = data
        a
    except ValueError as e:
        raise newException(ValueError, fmt"Couldn't create Article from {data}, {e.msg}")

proc default*(_: typedesc[Article]): Article = initArticle(PyNone, 0)
emptyArt = default(Article)

proc initTypes*() =
    try:
        emptyArt = default(Article)
    except:
        try:
            echo fmt"types: failed to initialize default article {getCurrentExceptionMsg()}"
        except:
            emptyArt = static(Article())

import
    locktpl,
    tables


proc get*[K, V](t: Table[K, V], k: K): V = t[k] # the table module doesn't have this

lockedStore(Table)
lockedStore(LruCache)

export tables,
       locks

# Py
proc contains*[K](v: PyObject, k: K): bool =
    v.callMethod("__contains__", k).to(bool)


# PySequence
import quirks
type PySequence*[T] = ref object
    py: PyObject
    getitem: PyObject
    setitem: PyObject

proc initPySequence*[T](o: PyObject): PySequence[T] =
    new(result)
    result.py = o
    result.getitem = o.getAttr("__getitem__")
    result.setitem = o.getAttr("__setitem__")

proc `[]`*[S, K](s: PySequence[S], k: K): PyObject =
    s.getitem(k)

proc `slice`*[S](s: PySequence[S], start: int, stop: int, step = 1): PyObject =
    s.getitem(pySlice(start, stop, step))

proc `[]=`*[S, K, V](s: PySequence[S], k: K, v: S) =
    s.setitem(k, v)

proc `$`*(s: PySequence): string = $s.py

iterator items*[S](s: PySequence[S]): PyObject =
    for i in s.py:
        yield i

{.experimental: "dotOperators".}

import macros
macro `.()`*(o: PySequence, field: untyped, args: varargs[untyped]): untyped =
    quote do:
        `o`.py.`field`(`args`)

macro `.`*(o: PySequence, field: untyped): untyped =
    quote do:
        `o`.py.`field`

macro `.=`*(o: PySequence, field: untyped, value: untyped): untyped =
    quote do:
        `o`.py.`field` = `value`

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
