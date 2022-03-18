import nimpy
import tables
import sets

type
    service* = enum
        deep_translator = "deep_translator"
    Lang* = tuple
        name: string
        code: string
    langPair* = tuple[src: string, trg: string]
    tFunc = PyObject
    tTable = Table[langPair, tFunc]
    Translator* = ref object
        py: PyObject
        tr: tTable
        apis: HashSet[string]
        name: service

const default_service* = deep_translator
