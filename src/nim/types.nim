import times
import nimpy
import parseutils
import strutils

type
    DT = enum
        str,
        date
    DateString = object
        case kind: DT
        of str: str: string
        of date: date: DateTime

    Article* = ref object
        title*: string
        desc*: string
        content*: string
        author*: string
        pubDate*: Time
        imageUrl*: string
        icon*: string
        url*: string
        lang*: string

# proc initArticle()

# https://github.com/yglukhov/nimpy/issues/164
let
  builtins = pyBuiltinsModule()
  PyBoolClass = builtins.True.getattr("__class__")
  PyNoneClass = builtins.None.getattr("__class__")
  PyDateTimeClass = pyimport("datetime").datetime
  PyStrClass = builtins.str.getattr("__class__")

proc pyisbool*(py: PyObject): bool {.exportpy.} =
  return builtins.isinstance(py, PyBoolClass).to(bool)

proc pyisnone*(py: PyObject): bool {.exportpy.} =
  return builtins.isinstance(py, PyNoneClass).to(bool)

proc pyisdatetime*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyDateTimeClass).to(bool)

proc pyisstr*(py: PyObject): bool {.exportpy.} =
    return builtins.isinstance(py, PyStrClass).to(bool)

proc `$`*(a: Article): string =
    "title: " &
        a.title &
        "\pdate: " &
        $a.pubDate &
        "\purl: "  &
        a.url

proc pydate*(py: PyObject, default=getTime()): Time =
    if pyisnone(py):
        return default
    else:
        return py.timestamp().to(float).fromUnixFloat()

var e: ref ValueError
new(e)
e.msg = "All python objects were None."

proc pysome*(pys: varargs[PyObject], default=new(PyObject)): PyObject =
    for py in pys:
        if pyisnone(py):
            continue
        else:
            return py
    raise e

proc pyget*[T](py: PyObject, def: T): T =
    if pyisnone(py):
        return def
    else:
        return py.to(T)
