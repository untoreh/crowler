import strutils,
       nimpy,
       nimpy/py_lib {.all.},
       os,
       strformat,
       chronos,
       locks,
       macros
import times except milliseconds

export nimpy
export pyLib, locks
mixin config

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

template withPyLock*(code): untyped =
  {.locks: [pyGil].}:
    try:
      await pygil.acquire()
      code
    finally:
      pygil.release()

template withOutPylock*(code): untyped =
  try:
    pygil.release()
    code
  finally:
    await pygil.acquire()

template syncPyLock*(code): auto =
  {.locks: [pyGil].}:
    try:
      pygil.globalAcquire()
      code
    finally:
      pygil.release()

template togglePyLock*(flag: static[bool] = true; code): untyped =
  when flag:
    withPyLock(code)
  else:
    code

template fPyLocked*(code) =
  {.locks: [pyGil].}:
    code

# in release mode cwd is not src/nim
let
  prefixPy =
    if dirExists "py": "py"
    elif dirExists "lib/py": "lib/py"
    elif dirExists "../py": "../py"
    elif dirExists "../src/py": "../src/py"
    else: raise newException(Defect, "could not find python library path. in {getAppFileName.parentDir}")

proc relpyImport*(relpath: string; prefix = prefixPy): PyObject =
  ## All relative python imports inside the relatively imported module (from .. import $mod)
  ## must be (relatively) imported (discard relPyImport...)
  ## before the desired (relatively) imported target module.
  let abspath = os.expandFilename(prefix) / relpath & ".py"
  try:
    let
      pysys = pyImport("sys")
      pyimutil = pyImport("importlib.util")
      name = abspath.splitFile[1]
      spec = pyimutil.spec_from_file_location(name, abspath)
      pymodule = pyimutil.module_from_spec(spec)
    pysys.modules[name] = pymodule
    discard spec.loader.exec_module(pymodule)
    return pyImport(name.cstring)
  except:
    let e = getCurrentException()[]
    raise newException(ValueError, fmt"Cannot import python module, pwd is {getCurrentDir()}, trying to load {abspath} {'\n'} {e}")

{.push guard: pyGil.}
pygil.globalAcquire()
import cfg
block:
  when declared(PROJECT_PATH):
    let pypath = PROJECT_PATH / "lib" / "py"
    if dirExists(pypath):
      let sys = pyImport("sys")
      discard sys.path.append(pypath)

macro pyObjExp*(defs: varargs[untyped]): untyped =
  result = newNimNode(nnkStmtList)
  for d in defs:
    let
      name = d[0]
      def = d[1]
    result.add quote do:
      var `name`* {.guard: pyGil, threadvar.}: PyObject
      `name` = `def`

macro pyObjPtr*(defs: varargs[untyped]): untyped =
  result = newNimNode(nnkStmtList)
  for d in defs:
    let
      name = d[0]
      def = d[1]
    result.add quote do:
      let `name` {.guard: pyGil.} = create(PyObject)
      `name`[] = `def`

macro pyObjPtrExp*(defs: varargs[untyped]): untyped =
  result = newNimNode(nnkStmtList)
  for d in defs:
    let
      name = d[0]
      def = d[1]
    result.add quote do:
      let `name`* {.guard: pyGil.} = create(PyObject)
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
    (PyZArray, pyza[].getAttr("Array"))
)
when os.getEnv("PYTHON_PROFILING", "").len > 0:
  pyObjPtr((pyTracker,
            block:
              let
                mr = pyimport("memray")
                out_path = os.getEnv("PYTHON_PROFILING", "")
                out_split = splitfile(out_path)
              doassert out_split.dir.dirExists and out_split.name.len > 0
              discard tryRemoveFile(out_path)
              mr.Tracker(out_path, native_traces = true)
              ))
  discard pyTracker[].callMethod("__enter__")
  import std/exitprocs
  proc stopPyTracker() =
    syncPyLock():
      let none = pybi[].getAttr("None")
      discard pyTracker[].callMethod("__exit__", [none, none, none])
  addExitProc(stopPyTracker)
pygil.release()
{.pop.}

var PyNone* {.threadvar.}: PyObject
var site* {.guard: pyGil, threadvar.}: PyObject

from utils import withLocks
proc pyhasAttr*(o: PyObject; a: string): bool {.withLocks: [pyGil].} = pybi[
  ].hasattr(o, a).to(bool)

proc pyclass(py: PyObject): PyObject {.inline, withLocks: [pyGil].} =
  pybi[].type(py)

proc pytype*(py: PyObject): string =
  py.pyclass.getattr("__name__").to(string)

proc pyisbool*(py: PyObject): bool {.withLocks: [pyGil].} =
  return pybi[].isinstance(py, PyBoolClass[]).to(bool)

proc pyisnone*(py: PyObject): bool {.gcsafe, withLocks: [pyGil].} =
  return py.isnil or pybi[].isinstance(py, PyNoneClass[]).to(bool)

proc pyisdatetime*(py: PyObject): bool {.withLocks: [pyGil].} =
  return pybi[].isinstance(py, PyDateTimeClass[]).to(bool)

proc pyisstr*(py: PyObject): bool {.withLocks: [pyGil].} =
  return pybi[].isinstance(py, PyStrClass[]).to(bool)

proc pyisint*(py: PyObject): bool {.withLocks: [pyGil].} =
  return pybi[].isinstance(py, pybi[].getattr("int")).to(bool)

proc pyiszarray*(py: PyObject): bool {.withLocks: [pyGil].} =
  return pybi[].isinstance(py, PyZArray[]).to(bool)

const ymdFormat* = "yyyy-MM-dd"
const isoFormat* = "yyyy-MM-dd'T'HH:mm:ss"

proc pydate*(py: PyObject; default = getTime()): Time =
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
when false:
  let pycfg* = pyImport("config")
  doassert not pyisnone(pycfg)
  discard pyImport("log")
  discard pyImport("blacklist")

pyObjExp((ut, pyImport("utils")))
doassert not pyisnone(ut)
when not SERVER_MODE:
  pyObjPtrExp(
      (pySched, pyImport("scheduler")),
      (pySchedApply, pySched[].getAttr("apply"))
  )
  doassert not pyisnone(pySched[])
# Proxies
when false:
  pyObjPtr(
    (pyProxies, pyImport("proxies_pb"))
  )
  proc pyGetProxy*(st: bool = true): Future[string] {.async.} =
    withPyLock():
      let prx = callMethod(pyProxies[], "get_proxy", st)
      if not pyisnone(prx):
        return prx.to(string)
pygil.release()

echo "pyutils (base) initialized." # Should eval inside try/catch but pyobj macros are not compatible (they export definitions)

proc initPy*() =
  try:
    syncPyLock:
      if PyNone.isnil:
        PyNone = pybi[].getattr("None")
      if pyisnone(site):
        echo "pyutils.nim:257"
        site = pyImport("sites").Site(config.websiteName)
        echo "pyutils.nim:259"
        doassert not pyisnone(site)
  except:
    let e = getCurrentException()
    echo "Can't initialize python site object for " & config.websiteName
    if not e.isnil:
      echo e[]
    quit()

pygil.globalAcquire()
let pysliceObj = pybi[].slice
let pySlice = pysliceObj.unsafeAddr
pygil.release()

proc contains*[K](v: PyObject; k: K): bool =
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

proc `[]`*[S, K](s: PySequence[S]; k: K): PyObject =
  s.getitem(k)

proc `slice`*[S](s: PySequence[S]; start: int | PyObject; stop: int | PyObject;
    step = 1): PyObject {.gcsafe.} =
  s.getitem(pySlice[](start, stop, step))

proc `[]=`*[S, K, V](s: PySequence[S]; k: K; v: S) =
  s.setitem(k, v)

proc `$`*[T](s: PySequence[T]): string =
  if s.isnil or s.py.isnil:
    ""
  else:
    pybi[](s.py).to(string)

proc len*(s: PySequence): int = s.py.len

iterator items*[S](s: PySequence[S]): PyObject =
  for i in s.py:
    yield i

{.experimental: "dotOperators".}

macro `.()`*(o: PySequence; field: untyped; args: varargs[untyped]): untyped =
  quote do:
    `o`.py.`field`(`args`)

macro `.`*(o: PySequence; field: untyped): untyped =
  quote do:
    `o`.py.`field`

macro `.=`*(o: PySequence; field: untyped; value: untyped): untyped =
  quote do:
    `o`.py.`field` = `value`

proc pysome*(pys: varargs[PyObject]; default = new(PyObject)): PyObject =
  for py in pys:
    if pyisnone(py):
      continue
    else:
      return py
  raise newException(ValueError, "All python objects were None.")

proc len*(py: PyObject): int {.withLocks: [pyGil].} =
  pybi[].len(py).to(int)

proc isa*(py: PyObject; tp: PyObject): bool {.withLocks: [pyGil].} =
  pybi[].isinstance(py, tp).to(bool)

import utils

proc pyget*[T](py: PyObject; k: string; def: T = ""): T =
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

import quirks
import std/importutils
proc pywait*(j: PyObject): Future[PyObject] {.async, gcsafe.} =
  var rdy: bool
  var res: PyObject
  while true:
    withPyLock:
      checkNil(j)
      rdy = j.callMethod("ready").to(bool)
    if rdy:
      withPyLock:
        checkNil(j)
        res = j.callMethod("get")
      break
    await sleepAsync(250.milliseconds)
  withPyLock:
    if (not res.isnil) and (not pyisnone(res)) and (not pyErrOccurred()):
      return res
    else:
      raise newException(ValueError, "Python job failed.")

converter pyToSeqStr*(py: PyObject): seq[string] =
  for el in py:
    result.add el.to(string)

type PyDict* = PyObject
proc topy*[T](tbl: T; _: typedesc[PyDict]): PyDict =
  static:
    doassert:
      compiles:
        for (k, v) in tbl.pairs: discard
  {.locks: [pygil].}:
    result = pybi[].dict()
    for (k, v) in tbl.pairs():
      result["k"] = v
