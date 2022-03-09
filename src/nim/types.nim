import times
import nimpy
import parseutils
import strutils

type
    TS = enum
        str,
        time
    TimeString = object
        case kind: TS
        of str: str: string
        of time: time: Time

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
        tags*: seq[string]

# proc initArticle()

# https://github.com/yglukhov/nimpy/issues/164
let
    builtins = pyBuiltinsModule()
    za = pyimport("zarr")
    PyBoolClass = builtins.True.getattr("__class__")
    PyNoneClass = builtins.None.getattr("__class__")
    PyDateTimeClass = pyimport("datetime").datetime
    PyStrClass = builtins.str.getattr("__class__")
    PyZArray = za.getAttr("Array")

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

const ymdFormat = "yyyy-MM-dd"
const isoFormat = "yyyy-MM-dd'T'HH:mm:ss"

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

proc pyget*[T](py: PyObject, k: string, def: T = ""): T =
    let v = py.get(k)
    if pyisnone(v):
        return def
    else:
        return v.to(T)

type
    topicData* = enum
        articles = "articles",
        feeds =  "feeds",
        done = "done"
    # topicData = object
    #     case kind: topicDataType
    #     of articles: articles: string
    #     of feeds: feeds: string
    #     of done: done: string
