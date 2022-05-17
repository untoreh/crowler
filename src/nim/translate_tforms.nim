import locks,
       sets,
       tables,
       os,
       xmltree,
       karax/vdom,
       macros,
       uri,
       strutils

import
    cfg,
    translate_types,
    utils,
    ldj

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

proc head_tform(el: VNode, basedir: string, relpath: string, pair: langPair) {.gcsafe.} =
    let
        srcUrl = $(WEBSITE_URL / relpath)
        trgUrl =  $(WEBSITE_URL / pair.trg / relpath)
    var title, desc, img, date: string
    var tags: seq[string]
    var stack = 6 # how many variables do we have to set
    for el in el.preorder:
        case el.kind:
            of link:
                case el.getAttr("rel"):
                    of $canonical:
                        rewriteUrl(el, pair.trg)
                        stack -= 1
                    of $alternate:
                        if (not el.hasAttr("hreflang")):
                            rewriteUrl(el, pair.trg)
                    of $amphtml:
                        rewriteUrl(el, ("amp/" & pair.trg))
                        stack -= 1
                    else: discard
            of meta:
                case el.getAttr("name"):
                    of "description":
                        desc = el.getAttr("content")
                        stack -= 1
                    of "title":
                        title = el.getAttr("content")
                        stack -= 1
                    of "keywords":
                        tags = el.getAttr("content").split(",")
                        stack -= 1
                    of "image":
                        img = el.getAttr("content")
                        stack -= 1
                    of "date":
                        date = el.getAttr("content")
                        stack -= 1
                    else: discard
            else: discard
        if stack < 0: break
    let ldjTrans = translation(srcUrl, trgUrl, pair.trg, title, date, HTML_POST_SELECTOR, desc, tags, img)

proc initTforms*() =
    vtransforms[][VNodeKind.head] = head_tform


# when isMainModule:
#     import cfg, types, server_types, nimpy, strutils, articles, pages, search
#     import translate_types, translate_lang, translate
#     translate.initThread()
#     initSonic()
#     let path = "/web/0/20-best-web-hosting-for-small-business-2022-reviews"
#     var capts = uriTuple(path)
#     let pair = (src: "en", trg: "it")
#     # let py = getArticlePy(capts.topic, capts.page, capts.art)
#     # let a = initArticle(py, parseInt(capts.page))
#     let tree = articleTree(capts)
#     capts.lang = "it"
#     var x: (int, int)
#     let
#         filedir = SITE_PATH
#         relpath = "index.html"
#         tpath = join(capts)
#     var fc = initFileContext(tree, SITE_PATH, path, pair, tpath)
#     # debug "page: translating home to {lang}"
#     vtransforms[][VNodeKind.head] = head_tform
