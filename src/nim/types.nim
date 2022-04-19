import
    times, nimpy, os, strutils, strformat,
    nimpy / py_lib,
    std / osproc,
    sets, locks, sequtils


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

type
    TS = enum
        str,
        time
    # TimeString = object
    #     case kind: TS
    #     of str: str: string
    #     of time: time: Time

    Article* = ref object
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
    PyZArray = za.getAttr("Array")
    PyNone* = builtins.None
    pySlice = builtins.slice

var emptyArt* {.threadvar.}: Article
emptyArt = static(Article())

proc pytype*(py: PyObject): string =
    builtins.type(py).getattr("__name__").to(string)

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
    let v = py.get(k)
    if pyisnone(v):
        return def
    else:
        return v.to(T)

type
    topicData* = enum
        articles = "articles",
        feeds = "feeds",
        done = "done"
        pages = "pages"

proc initArticle*(data: PyObject, pagenum: int): Article =
    let a = new(Article)
    a.title = pyget(data, "title")
    a.desc = pyget(data, "desc")
    a.content = pyget(data, "content")
    a.author = pyget(data, "author")
    a.pubDate = pydate(data.get("pubDate"), getTIme())
    a.imageUrl = pyget(data, "imageUrl")
    a.icon = pyget(data, "icon")
    a.url = pyget(data, "url")
    a.slug = pyget(data, "slug")
    a.lang = pyget(data, "lang")
    a.topic = pyget(data, "topic")
    a.page = pyget(data, "page", pagenum)
    a.tags = pyget(data, "tags", emptyseq)
    a.py = data
    a

import tables

export tables,
       locks

type
    LockTableObj[K, V] = object
        lock: Lock
        storage {.guard: lock.}: ref Table[K, V]
    LockTable*[K, V] = ptr LockTableObj[K, V]

proc initLockTable*[K; V](): LockTable[K, V] =
    result = create(LockTableObj[K, V])
    initLock(result.lock)
    var tbl = new(Table[K, V])
    withLock(result.lock):
        result.storage = tbl

iterator items*(tbl: LockTable): auto =
    withLock(tbl.lock):
        for (k, v) in tbl.storage.pairs():
            yield (k, v)

proc `[]=`*(tbl: LockTable, k, v: auto) =
    withLock(tbl.lock):
        tbl.storage[k] = v

proc `[]`*(tbl: LockTable, k: auto): auto =
    withLock(tbl.lock):
        return tbl.storage[k]

proc contains*[T](tbl: LockTable, k: T) =
    withLock(tbl.lock):
        return k in tbl.storage

proc clear*(tbl: LockTable) =
    withLock(tbl.lock):
        clear(tbl.storage)

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
type PathLock* = LockTable[string, Lock]
var locksBuffer* {.threadvar.}: seq[Lock]
locksBuffer.setLen(100)

proc initPathLock*(): PathLock = initLockTable[string, Lock]()

proc get*(b: var seq[Lock]): Lock =
    try:
        return b.pop()
    except:
        b.setLen(100)
        return b.pop()

proc contains*(pl: PathLock, k: string): bool = k in pl

proc waitOrAcquire*(pl: PathLock, k: string): bool =
    var taken: bool
    var l: Lock
    try:
        l = pl[k]
        l.acquire
        l.release
        result = true
    except KeyError:
        pl[k] = locksBuffer.get
        l = pl[k]
        l.acquire
        result = false

proc release*(pl: PathLock, k: string) =
    try:
        var l = pl[k]
        l.release()
    except KeyError: discard
