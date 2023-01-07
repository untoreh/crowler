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
    types,
    translate_types,
    utils,
    ldj

type
    TransformFunc* = proc(fc: FileContext, el: XmlNode, file: string, url: string, pair: langPair) {.gcsafe.}
    VTransformFunc* = proc(fc: FileContext, el: VNode, file: string, url: string, pair: langPair) {.gcsafe.}
    TFormsTable = LockTable[string, TransformFunc]
    VTFormsTable = LockTable[VNodeKind, VTransformFunc]
    TForms = ptr TFormsTable
    VTForms = ptr VTFormsTable

# var transformsTable = initTable[string, TransformFunc]()
let transforms* = initLockTable[string, TransformFunc]()
let vtransforms* = initLockTable[VNodeKind, VTransformFunc]()

# var tfLock: Lock
# initLock(tfLock)

macro getTforms*(kind: static[FcKind]): untyped =
    case kind:
        of xml:
            quote do: transforms
        else:
            quote do: vtransforms

proc head_tform(fc: FileContext, el: VNode, basedir: string, relpath: string, pair: langPair) {.gcsafe.} =
    let
        srcUrl = $(fc.config.websiteUrl / relpath)
        trgUrl = $(fc.config.websiteUrl / pair.trg / relpath)
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
                        let href = el.getattr("href")
                        el.setAttr("href", href.replace(sre "amp/?", ""))
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
    let ldjTrans = translation(srcUrl, trgUrl, pair.trg, title, date, HTML_POST_SELECTOR, desc,
            tags, img)
    el.add ldjTrans.asVNode

proc breadcrumb_tform(fc: FileContext, el: VNode, basedir: string, relpath: string, pair: langPair) =
  let node = el.find(VNodeKind.a, "breadcrumb-lang-link")
  if node.kind == VNodeKind.a:
    let txt = node.find(VNodeKind.text)
    if len(node) == 2 and node[1].kind == VNodeKind.text:
      node[1].value = pair.trg

proc initTforms*() =
    vtransforms[VNodeKind.head] = head_tform
    vtransforms[VNodeKind.section] = breadcrumb_tform


# when isMainModule:
#     import cfg, types, server_types, nimpy, strutils, articles, pages, search
#     import translate_types, translate_lang, translate
#     translate.initThread()
#     initSonic()
#     let path = "/web/0/20-best-web-hosting-for-small-business-2022-reviews"
#     var capts = uriTuple(path)
#     let pair = (src: "en", trg: "it")
#     # let py = getArticlePy(capts.topic, capts.page, capts.art)
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
