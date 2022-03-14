import nimpy
import osproc
import strutils
import strformat
import os
import tables

type service = enum
    deep_translator = "deep_translator"

const default_service = deep_translator
let pybi = pyBuiltinsModule()

type langPair = tuple[src: string, trg: string]
type tFunc = proc(t: string) : string
type tTable = Table[string, tFunc]
type Translator = ref object
        py: PyObject
        tr: tTable
        apis:
        name: service


proc ensurePy(srv: service): PyObject =
    try:
        return pyImport($srv)
    except Exception as e:
        if "ModuleNotFoundError" in e.msg:
            if getEnv("VIRTUAL_ENV", "") != "":
                let res = execCmd(fmt"pip install {srv}")
                if res != 0:
                    raise newException(OSError, fmt"Failed to install {srv}, check your python virtual environment.")
            else:
                raise newException(OSError, "Can't install modules because not in a python virtual env.")
        else:
            raise e

let tr = ensurePy(default_service)

proc initTranslator(srv: service) =
    case srv:
        of deep_translator:
            for cls in tr.apis:



when isMainModule:
