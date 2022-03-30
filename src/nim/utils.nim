import os
import sets
import cfg
import sugar
import deques
import nre
import strutils
import strformat
import xmltree
import translate_types
import strtabs
import macros
import locks
import weave
import karax / vdom
export weave

var loggingLock: Lock
initLock(loggingLock)

template logstring(code: untyped): untyped =
    # fmt"{getThreadId(Weave)} - " & fmt code
    fmt code

macro debug*(code: untyped): untyped =
    if not defined(release) and logLevelMacro != lvlNone:
        quote do:
            withLock(loggingLock):
                logger[].log lvlDebug, logstring(`code`)
    else:
        quote do:
            discard

macro warn*(code: untyped): untyped =
    if logLevelMacro >= lvlWarn:
        quote do:
            loggingLock.acquire()
            logger[].log lvlWarn, fmt logstring(`code`)
            loggingLock.release()
    else:
        quote do:
            discard

macro info*(code: untyped): untyped =
    if logLevelMacro <= lvlInfo:
        quote do:
            loggingLock.acquire()
            logger[].log lvlInfo, logstring(`code`)
            loggingLock.release()
    else:
        quote do:
            discard

macro toggle*(flag: static[bool], code: untyped): untyped =
    if flag == true:
        quote do:
            `code`
    else:
        quote do:
            discard

type StringSet = HashSet[string]

converter asStringSet(v: openarray[string]): StringSet = to_hashset[string](v)
const exts = [".htm", ".html"]

proc fileExtension(path: string): string {.inline.} =
    let pos = searchExtPos(path)
    if pos != -1:
        result = path[pos..^1]

iterator filterFiles*(root: string;
                   exts: Stringset = exts.asStringSet;
                   excl_dirs: StringSet = [];
                   top_dirs: StringSet = [];
                  ): string {.closure.} =
    ## A directory iterator:
    ## `exts`: which file extensions should be included
    ## `excl_dirs`: directory names that are skipped on every node (blacklist)
    ## `top_dirs`: directory names that are included only at top node (subnodes only respect `excl_dirs`)
    let rootAbs = expandFilename(root)
    var
        path: string
        kind: PathComponent
        topfiles = collect:
            for p in walkDir(rootAbs):
                if p.kind == pcDir or p.kind == pcLinkToDir:
                    let n = p.path.absolutePath.lastPathPart
                    if (not (n in excl_dirs)) and (len(top_dirs) == 0 or n in top_dirs):
                        p
                elif p.path.fileExtension in exts:
                    p
        files = topfiles.toDeque
        processed: StringSet
    while len(files) > 0:
        (kind, path) = files.popFirst
        path = absolutePath(path)
        # this allows to skip symlinks
        if path in processed:
            continue
        if kind == pcDir:
            if path.lastPathPart in excl_dirs:
                continue
            else:
                for f in walkDir(path):
                    files.addlast(f)
        # only follow symlinked dirs if they don't point inside the root directory
        elif kind == pcLinkToDir:
            if rootAbs in path:
                continue
            else:
                for f in walkDir(path):
                    files.addlast(f)
        elif path.fileExtension in exts:
            yield path
            processed.incl(path)

iterator preorder*(tree: XmlNode): XmlNode =
    ## Iterator, skipping tags in `skip_nodes`
    ## also skipping comments, entities, CDATA and zero-length text nodes
    var stack = @[tree]
    while stack.len > 0:
        var node = stack.pop()
        case node.kind:
            of xnComment, xnEntity, xnCData:
                continue
            of xnText, xnVerbatimText:
                if len(node.text) == 0:
                    continue
                else:
                    yield node
            of xnElement:
                case node.tag:
                    of skip_nodes:
                        continue
                    else:
                        if (not node.attrs.isnil) and node.attrs.haskey("class"):
                            var cls = false
                            let node_classes = node.attrs["class"].split().toHashSet
                            for class in skip_class:
                                if class in node_classes:
                                    cls = true
                                    break
                            if cls:
                                continue
                        for c in mitems(node):
                            stack.add(c)
            else:
                yield node

proc key*(s: string): array[5, byte] =
    case s.len
         of 0: result = default(array[5, byte])
         else:
             let ln = s.len
             result = cast[array[5, byte]]([s[0], s[ln /% 4], s[ln /% 3], s[ln /% 2], s[ln - 1]])

iterator preorder*(tree: VNode): VNode =
    ## Iterator, skipping tags in `skip_nodes`
    ## also skipping comments, entities, CDATA and zero-length text nodes
    var stack = @[tree]
    while stack.len > 0:
        var node = stack.pop()
        case node.kind:
            of VNodeKind.text:
                if len(node.text) == 0:
                    continue
                else:
                    yield node
            of skip_vnodes:
                continue
            else:
                var cls = false
                for class in skip_class:
                    if class in node.class:
                        cls = true
                        break
                if cls: continue
                for c in node.items():
                    stack.add(c)
                yield node

iterator flatorder*(tree: var XmlNode): XmlNode {.closure.} =
    for el in mitems(tree):
        if len(el) > 0:
            let po = flatorder
            for e in po(el):
                yield e
        yield el


proc getText*(el: XmlNode): string =
    case el.kind:
        of xnText, xnVerbatimText:
            result = el.text
        else:
            result = el.attrs.getOrDefault("alt", "")
            if result == "":
               result = el.attrs.getOrDefault("title", "")

proc getText*(el: VNode): string =
    case el.kind:
        of VNodeKind.text:
            result = el.text
        else:
            result = el.getAttr("alt")
            if result == "":
                result = el.getAttr("title")

proc setText*(el: XmlNode, v: auto) =
    case el.kind:
        of xnText, xnVerbatimText:
            el.text = v
        else:
            if hasKey(el.attrs, "alt"):
                el.attrs["alt"] = v
            else:
                el.attrs["title"] = v

proc setText*(el: VNode, v: auto) =
    case el.kind:
        of VNodeKind.text:
            el.text = v
        else:
            if el.getAttr("alt") != "":
                el.setAttr("alt", v)
            else:
                el.setAttr("title", v)

proc hasAttr*(el: VNode, k: string): bool =
    for (i, v) in el.attrs:
        if i == v:
            return true
    return false

proc hasAttr*(el: XmlNode, k: string): bool = el.attrs.haskey k
proc getAttr*(el: XmlNode, k: string): string = el.attrs[k]
proc setAttr*(el: XmlNode, k: string, v: auto) = el.attrs[k] = v

proc replaceTilNoChange(input: var auto, pattern, repl: auto): string =
    while pattern in input:
        input = input.replace(pattern, repl)
    input

let
    sentsRgx1 = re"([?!.])\s"
    sentsRgx2 = re"\r"
    sentsRgx3 = re"\b([a-z]+\?) ([A-Z][a-z]+)\b"
    sentsRgx4 = re"\b([a-z]+ \.) ([A-Z][a-z]+)\b"
    sentsRgx5 = re"\n([.!?]+)\n"
    sentsRgx6 = re"\[([^\[\]\(\)]*)\n([^\[\]\(\)]*)\]"
    sentsRgx7 = re"\(([^\[\]\(\)]*)\n([^\[\]\(\)]*)\)"
    sentsRgx8 = re"\[([^\[\]]{0,250})\n([^\[\]]{0,250})\]"
    sentsRgx9 = re"\(([^\(\)]{0,250})\n([^\(\)]{0,250})\)"
    sentsRgx10 = re"\[((?:[^\[\]]|\[[^\[\]]*\]){0,250})\n((?:[^\[\]]|\[[^\[\]]*\]){0,250})\]"
    sentsRgx11 = re"\(((?:[^\(\)]|\([^\(\)]*\)){0,250})\n((?:[^\(\)]|\([^\(\)]*\)){0,250})\)"
    sentsRgx12 = re"\.\n([a-z]{3}[a-z-]{0,}[ \.\:\,])"
    sentsRgx13 = re"(\b[A-HJ-Z]\.)\n"
    sentsRgx14 = re"\n(and )"
    sentsRgx15 = re"\n(or )"
    sentsRgx16 = re"\n(but )"
    sentsRgx17 = re"\n(nor )"
    sentsRgx18 = re"\n(yet )"
    sentsRgx19 = re"\n(of )"
    sentsRgx20 = re"\n(in )"
    sentsRgx21 = re"\n(by )"
    sentsRgx22 = re"\n(as )"
    sentsRgx23 = re"\n(on )"
    sentsRgx24 = re"\n(at )"
    sentsRgx25 = re"\n(to )"
    sentsRgx26 = re"\n(via )"
    sentsRgx27 = re"\n(for )"
    sentsRgx28 = re"\n(with )"
    sentsRgx29 = re"\n(that )"
    sentsRgx30 = re"\n(than )"
    sentsRgx31 = re"\n(from )"
    sentsRgx32 = re"\n(into )"
    sentsRgx33 = re"\n(upon )"
    sentsRgx34 = re"\n(after )"
    sentsRgx35 = re"\n(while )"
    sentsRgx36 = re"\n(during )"
    sentsRgx37 = re"\n(within )"
    sentsRgx38 = re"\n(through )"
    sentsRgx39 = re"\n(between )"
    sentsRgx40 = re"\n(whereas )"
    sentsRgx41 = re"\n(whether )"
    sentsRgx42 = re"(\be\.)\n(g\.)"
    sentsRgx43 = re"(\bi\.)\n(e\.)"
    sentsRgx44 = re"(\bi\.)\n(v\.)"
    sentsRgx45 = re"(\be\. ?g\.)\n"
    sentsRgx46 = re"(\bi\. ?e\.)\n"
    sentsRgx47 = re"(\bi\. ?v\.)\n"
    sentsRgx48 = re"(\bvs\.)\n"
    sentsRgx49 = re"(\bcf\.)\n"
    sentsRgx50 = re"(\bDr\.)\n"
    sentsRgx51 = re"(\bMr\.)\n"
    sentsRgx52 = re"(\bMs\.)\n"
    sentsRgx53 = re"(\bMrs\.)\n"
    sentsRgx54 = re"\n"


proc splitSentences*(text: string): seq[string] =
    {.cast(gcsafe).}:
        var sents = text.replace(sentsRgx1, "$1\n")
        sents = sents.replace(sentsRgx2, "")
        sents = sents.replace(sentsRgx3, "$1\n$2")
        sents = sents.replace(sentsRgx4, "$1\n$2")
        sents = sents.replace(sentsRgx5, "$1\n")

        sents = replaceTilNoChange(sents, sentsRgx6, "[$1 $2]")
        sents = replaceTilNoChange(sents, sentsRgx7, "[$1 $2]")

        sents = replaceTilNoChange(sents, sentsRgx8, "[$1 $2]")
        sents = replaceTilNoChange(sents, sentsRgx9, "($1 $2)")

        sents = replaceTilNoChange(sents, sentsRgx10, "[$1 $2]")
        sents = replaceTilNoChange(sents, sentsRgx11, "($1 $2)")

        sents = replace(sents, sentsRgx12, ". $1")

        sents = replace(sents, sentsRgx13, "$1 ")

        sents = replace(sents, sentsRgx14, " $1")
        sents = replace(sents, sentsRgx15, " $1")
        sents = replace(sents, sentsRgx16, " $1")
        sents = replace(sents, sentsRgx17, " $1")
        sents = replace(sents, sentsRgx18, " $1")
        # or IN. (this is nothing like a "complete" list...)
        sents = replace(sents, sentsRgx19, " $1")
        sents = replace(sents, sentsRgx20, " $1")
        sents = replace(sents, sentsRgx21, " $1")
        sents = replace(sents, sentsRgx22, " $1")
        sents = replace(sents, sentsRgx23, " $1")
        sents = replace(sents, sentsRgx24, " $1")
        sents = replace(sents, sentsRgx25, " $1")
        sents = replace(sents, sentsRgx26, " $1")
        sents = replace(sents, sentsRgx27, " $1")
        sents = replace(sents, sentsRgx28, " $1")
        sents = replace(sents, sentsRgx29, " $1")
        sents = replace(sents, sentsRgx30, " $1")
        sents = replace(sents, sentsRgx31, " $1")
        sents = replace(sents, sentsRgx32, " $1")
        sents = replace(sents, sentsRgx33, " $1")
        sents = replace(sents, sentsRgx34, " $1")
        sents = replace(sents, sentsRgx35, " $1")
        sents = replace(sents, sentsRgx36, " $1")
        sents = replace(sents, sentsRgx37, " $1")
        sents = replace(sents, sentsRgx38, " $1")
        sents = replace(sents, sentsRgx39, " $1")
        sents = replace(sents, sentsRgx40, " $1")
        sents = replace(sents, sentsRgx41, " $1")

        # no sentence breaks in the middle of specific abbreviations
        sents = replace(sents, sentsRgx42, "$1 $2")
        sents = replace(sents, sentsRgx43, "$1 $2")
        sents = replace(sents, sentsRgx44, "$1 $2")

        # no sentence break after specific abbreviations
        sents = replace(sents, sentsRgx45, "$1 ")
        sents = replace(sents, sentsRgx46, "$1 ")
        sents = replace(sents, sentsRgx47, "$1 ")
        sents = replace(sents, sentsRgx48, "$1 ")
        sents = replace(sents, sentsRgx49, "$1 ")
        sents = replace(sents, sentsRgx50, "$1 ")
        sents = replace(sents, sentsRgx51, "$1 ")
        sents = replace(sents, sentsRgx52, "$1 ")
        sents = replace(sents, sentsRgx53, "$1 ")

        sents.split(sentsRgx54)

import karax/karaxdsl
when isMainModule:
    let node = buildHtml(html):
        text "ciao!!!"
    echo key("ciaosidoaksdks")
