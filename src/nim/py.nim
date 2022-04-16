import strutils,
       nimpy,
       nre,
       nimpy/py_lib {.all.},
       dynlib,
       weave

proc cleanText*(text: string): string {.exportpy.} =
    multireplace(text, [("\n", "\n\n"),
                        ("(.)\1{4,}", "\n\n\1")
                        ])

type PyGILState_STATE = enum PyGILState_LOCKED, PyGILState_UNLOCKED

{.pragma: pyfunc, cdecl, gcsafe.}
initPyLibIfNeeded()
let
    m = pythonLibHandleForThisProcess()
    PyGILState_Ensure = cast[proc(): PyGILState_STATE {.pyfunc.}](m.symAddr("PyGILState_Ensure"))
    PyGILState_Release = cast[proc(s: PyGILState_STATE) {.pyfunc.}](m.symAddr("PyGILState_Release"))

template withGIL*(code) =
    let state = Py_GILState_Ensure()
    code
    Py_GILState_Release(state)

type GilLock* = object
        m: LibHandle
        s: PyGILState_STATE

proc initGilLock*(): ptr GilLock =
    result = create(GilLock)
    result.m = pythonLibHandleForThisProcess()

proc acquire*(g: ptr GilLock) = g.s = Py_GILState_Ensure()
proc release*(g: ptr GilLock) = Py_GILState_Release(g.s)
