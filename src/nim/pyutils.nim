import strutils,
       nimpy,
       nimpy/py_lib {.all.},
       os,
       strformat,
       times,
       chronos,
       locks,
       macros

export nimpy
export pyLib, locks

when defined(findPyLib):
    import osproc
    proc setPyLib() =
        var (pylibpath, success) = execCmdEx("python3 -c 'import find_libpython; print(find_libpython.find_libpython())'")
        if success != 0:
            let (_, pipsuccess) = execCmdEx("pip3 install find_libpython")
            assert pipsuccess == 0
        (pylibpath, success) = execCmdEx("python3 -c 'import find_libpython; print(find_libpython.find_libpython())'")
        assert success == 0
        pylibpath.stripLineEnd
        pyInitLibPath pylibpath
    setPyLib()

pygil.globalAcquire()
let pyGlo* = pyGlobals()
pygil.release()

template withPyLock*(code): auto =
    {.locks: [pyGilLock].}:
        try:
            # echo getThreadId(), " -- ", getCurrentProcessId(), " -- ", procName()
            await pygil.acquire()
            code
        except:
            raise getCurrentException()
        finally:
            # echo getThreadId(), " -- ", getCurrentProcessId(),  " -- unlocked"
            pygil.release()

template syncPyLock*(code): auto =
    {.locks: [pyGilLock].}:
        try:
            pygil.globalAcquire()
            code
        except:
            raise getCurrentException()
        finally:
            pygil.release()

# in release mode cwd is not src/nim
pygil.globalAcquire()
let
    prefixPy = if dirExists "py": "py"
               elif dirExists "lib/py": "lib/py"
               elif dirExists "../py": "../py"
               else: raise newException(Defect, "could not find python library path. in {getAppFileName.parentDir}")
    machinery = pyImport("importlib.machinery")
    pyimutil = pyImport("importlib.util")
    pysys = pyImport("sys")
pygil.release()

proc relpyImport*(relpath: string, prefix = prefixPy): PyObject =
    ## All relative python imports inside the relatively imported module (from .. import $mod)
    ## must be (relatively) imported (discard relPyImport...)
    ## before the desired (relatively) imported target module.
    let abspath = os.expandFilename(prefix) / relpath & ".py"
    try:
        let
            name = abspath.splitFile[1]
            spec = pyimutil.spec_from_file_location(name, abspath)
            pymodule = pyimutil.module_from_spec(spec)
        pysys.modules[name] = pymodule
        discard spec.loader.exec_module(pymodule)
        return pyImport(name.cstring)
    except:
        let e = getCurrentException()[]
        raise newException(ValueError, fmt"Cannot import python module, pwd is {getCurrentDir()}, trying to load {abspath} {'\n'} {e}")

# we have to load the config before utils, otherwise the module is "partially initialized"
{.push guard: pyGilLock.}
pygil.globalAcquire()
import cfg
block:
    when declared(PROJECT_PATH):
        let pypath = PROJECT_PATH / "lib" / "py"
        if dirExists(pypath):
            let sys = pyImport("sys")
            discard sys.path.append(pypath)

macro pyObjPtr*(defs: varargs[untyped]): untyped =
  result = newNimNode(nnkStmtList)
  for d in defs:
    let
        name = d[0]
        def = d[1]
    result.add quote do:
        let `name` = create(PyObject)
        `name`[] = `def`

macro pyObjPtrExp*(defs: varargs[untyped]): untyped =
  result = newNimNode(nnkStmtList)
  for d in defs:
    let
        name = d[0]
        def = d[1]
    result.add quote do:
        let `name`* = create(PyObject)
        `name`[] = `def`

# https://github.com/yglukhov/nimpy/issues/164
pyObjPtrExp(
    (pybi, pyBuiltinsModule()),
    (pyza, pyimport("zarr")),
)
pyObjPtr(
    (PyBoolClass, pybi[].True.getattr("__class__")),
    (PyNoneClass, pybi[].None.getattr("__class__")),
    (PyDateTimeClass, pyimport("datetime").datetime),
    (PyStrClass, pybi[].getattr("str")),
    (PyIntClass, pybi[].getattr("int")),
    (PyDictClass, pybi[].getattr("dict")),
    ( PyZArray, pyza[].getAttr("Array"))
)
# let
    # pybi* = pyBuiltinsModule()
    # pyza* = pyimport("zarr")
    # PyBoolClass = pybi[].True.getattr("__class__")
    # PyNoneClass = pybi[].None.getattr("__class__")
    # PyDateTimeClass = pyimport("datetime").datetime
    # PyStrClass = pybi[].getattr("str")
    # PyIntClass = pybi[].getattr("int")
    # PyDictClass = pybi[].getattr("dict")
    # PyZArray = pyza.getAttr("Array")
pygil.release()
{.pop guard:pyGilLock.}
var PyNone* {.threadvar.}: PyObject

proc pyhasAttr*(o: PyObject, a: string): bool = pybi[].hasattr(o, a).to(bool)

proc pyclass(py: PyObject): PyObject {.inline.} =
    pybi[].type(py)

proc pytype*(py: PyObject): string =
    py.pyclass.getattr("__name__").to(string)

proc pyisbool*(py: PyObject): bool {.exportpy.} =
    return pybi[].isinstance(py, PyBoolClass[]).to(bool)

proc pyisnone*(py: PyObject): bool {.exportpy, gcsafe.} =
    assert not pybi[].isnil, "pyn: pybi should not be nil"
    assert pyhasAttr(pybi[], "isinstance"), "pyn: pybi[].isinstance should not be nil"
    assert not PyNoneClass[].isnil, "pyn: PyNoneClass should not be nil"
    let check = pybi[].isinstance(py, PyNoneClass[])
    assert not check.isnil, "pyn: check should not be nil"
    return py.isnil or check.to(bool)

proc pyisdatetime*(py: PyObject): bool {.exportpy.} =
    return pybi[].isinstance(py, PyDateTimeClass[]).to(bool)

proc pyisstr*(py: PyObject): bool {.exportpy.} =
    return pybi[].isinstance(py, PyStrClass[]).to(bool)

proc pyisint*(py: PyObject): bool {.exportpy.} =
    return pybi[].isinstance(py, pybi[].getattr("int")).to(bool)

proc pyiszarray*(py: PyObject): bool {.exportpy.} =
    return pybi[].isinstance(py, PyZArray[]).to(bool)


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

pygil.globalAcquire()
let pycfg* = pyImport("config")
doassert not pyisnone(pycfg)
discard pyImport("log")
let ut* = pyImport("utils")
doassert not pyisnone(ut)
discard pyImport("blacklist")
let site* = create(PyObject)
site[] = pyImport("sites").Site(WEBSITE_NAME)
doassert not pyisnone(site[])
# let pySched* = pyImport("scheduler")
pyObjPtrExp((pySched, pyImport("scheduler")))
doassert not pyisnone(pySched[])
discard pySched[].initPool()
pygil.release()

proc initPy*() =
    syncPyLock:
        try:
            PyNone = pybi[].getattr("None")
        except:
            echo "Can't initialize PyNone"
            quit()

pygil.globalAcquire()
let pyslice = create(PyObject)
pySlice[] = pybi[].slice
pygil.release()

proc contains*[K](v: PyObject, k: K): bool =
    v.callMethod("__contains__", k).to(bool)


# PySequence
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

proc `slice`*[S](s: PySequence[S], start: int, stop: int, step = 1): PyObject {.gcsafe.} =
    s.getitem(pySlice[](start, stop, step))

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
    pybi[].len(py).to(int)

proc isa*(py: PyObject, tp: PyObject): bool =
    pybi[].isinstance(py, tp).to(bool)

import utils

proc pyget*[T](py: PyObject, k: string, def: T = ""): T =
    try:
        let v = py.callMethod("get", k)
        if pyisnone(v):
            return def
        else:
            return v.to(T)
    except:
        pyErrClear()
        if pyisnone(py):
            return def
        else:
            return py.to(T)


# Exported
# proc cleanText*(text: string): string {.exportpy.} =
#     multireplace(text, [("\n", "\n\n"),
#                         ("(.)\1{4,}", "\n\n\1")
#                         ])
