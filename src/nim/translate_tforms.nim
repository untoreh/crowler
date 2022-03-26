import locks,
       sets,
       tables,
       os,
       xmltree

import translate_types

const skip_class = to_hashset[string]([])

type
    TransformFunc* = proc(el: XmlNode, file: string, url: string, pair: langPair) {.gcsafe.}
    TFormsTable = Table[string, TransformFunc]
    TForms = ptr TformsTable

var transformsTable = initTable[string, TransformFunc]()
let transforms* = transformsTable.addr

var tfLock: Lock
initLock(tfLock)

iterator keys*(tf: TForms): string =
    tfLock.acquire
    for k in tf[].keys:
        yield k
    tfLock.release

proc `[]`*(tf: TForms, k: string): TransformFunc =
    tf[][k]

proc `[]=`*(tf: TForms, k: string, v: TransformFunc): TransformFunc =
    tf[][k] = v
