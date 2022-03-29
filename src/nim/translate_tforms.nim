import locks,
       sets,
       tables,
       os,
       xmltree,
       karax/vdom,
       macros

import translate_types

const skip_class = to_hashset[string]([])

type
    TransformFunc* = proc(el: XmlNode, file: string, url: string, pair: langPair) {.gcsafe.}
    VTransformFunc* = proc(el: VNode, file: string, url: string, pair: langPair) {.gcsafe.}
    TFormsTable = Table[string, TransformFunc]
    VTFormsTable = Table[VNodeKind, VTransformFunc]
    TForms = ptr TFormsTable
    VTForms = ptr VTFormsTable

# var transformsTable = initTable[string, TransformFunc]()
let transforms* = create(TFormsTable)
let vtransforms* = create(VTFormsTable)

var tfLock: Lock
initLock(tfLock)

macro getTforms*(kind: static[FcKind]): untyped =
    case kind:
        of xml:
            quote do: transforms
        else:
            quote do: vtransforms

iterator keys*(tf: TForms): string =
    tfLock.acquire
    for k in tf[].keys:
        yield k
    tfLock.release

iterator keys*(tf: VTForms): VNodeKind =
    tfLock.acquire
    for k in tf[].keys:
        yield k
    tfLock.release

proc `[]`*(tf: TForms, k: string): TransformFunc =
    tf[][k]

proc `[]=`*(tf: TForms, k: string, v: TransformFunc): TransformFunc =
    tf[][k] = v

proc `[]`*(tf: VTForms, k: VNodeKind): VTransformFunc =
    tf[][k]

proc `[]=`*(tf: VTForms, k: VNodeKind, v: VTransformFunc): VTransformFunc =
    tf[][k] = v
