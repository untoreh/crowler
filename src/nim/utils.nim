import os,
       sets,
       cfg,
       sugar,
       deques,
       nre,
       strutils,
       strformat,
       xmltree,
       strtabs,
       macros,
       tables,
       sequtils,
       locks,
       uri,
       karax / vdom,
       std/importutils,
       normalize


import translate_types

static: echo "loading utils..."

type kstring = string
const baseUri* = initUri()

var loggingLock: Lock
initLock(loggingLock)

template procName*(): string = strutils.split(getStacktrace())[^2]

template lgetOrPut*[T, K](c: T, k: K, v: untyped): untyped =
    ## Lazy `mgetOrPut`
    mixin get, put
    try:
        c.get(k)
    except KeyError:
        c.put(k, v)

template lcheckOrPut*[T, K](c: T, k: K, v: untyped): untyped =
    ## Lazy `mgetOrPut`
    mixin get, contains, put, `[]`, `[]=`
    if k in c:
        c[k]
    else:
        c[k] = v
        c[k]

template alcheckOrPut*[T, K](c: T, k: K, v: untyped): untyped {.dirty.} =
    ## Lazy async `mgetOrPut`
    mixin get, contains, put, `[]`, `[]=`
    if (await (k in c)):
        await c[k]
    else:
        await c.put(k, v)
        await c[k]

template logstring(code: untyped): untyped =
    when not compileOption("threads"):
        procName() & " " & fmt code
    else:
        fmt"{getThreadId()} - " & fmt code

macro debug*(code: untyped): untyped =
    if not defined(release) and logLevelMacro != lvlNone:
        quote do:
            withLock(loggingLock):
                logger[].log lvlDebug, logstring(`code`)
    else:
        quote do:
            discard

macro logall*(code: untyped): untyped =
    if not defined(release) and logLevelMacro != lvlNone:
        quote do:
            withLock(loggingLock):
                logger[].log lvlAll, logstring(`code`)
    else:
        quote do:
            discard


template sdebug*(code) =
    try: debug code
    except: discard

template qdebug*(code) =
    try: debug code
    except: quit()

macro warn*(code: untyped): untyped =
    if logLevelMacro >= lvlWarn:
        quote do:
            withLock(loggingLock):
                logger[].log lvlWarn, fmt logstring(`code`)
    else:
        quote do:
            discard

template swarn*(code) =
    try: warn code
    except: discard

macro info*(code: untyped): untyped =
    if logLevelMacro <= lvlInfo:
        quote do:
            withLock(loggingLock):
                logger[].log lvlInfo, logstring(`code`)
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

macro apply*(fun, args: typed): untyped =
    result = newCall(fun)
    var funArgLen = getType(fun).len - 2
    case args.kind:
        of nnkBracket:
            for a in args:
                result.add a
        of nnkPrefix:
            if args[0].repr == "@":
                for a in args[1]:
                    result.add a
        of nnkTupleConstr:
            for a in args:
                result.add a
        of nnkSym:
            for i in 0..<funArgLen:
                var b = newTree(nnkBracketExpr)
                b.add args
                b.add newLit(i)
                result.add b
        else:
            error("unsupported kind: " & $args.kind & ", " & args.repr)
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

proc findnil*(tree: VNode) =
    for el in items(tree):
        if el.isnil:
            stdout.write "NIL\n"
        else:
            stdout.write $el.kind & "\n"
            if len(el) > 0:
                findnil(el)


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
                        yield node


proc findel*(tree: XmlNode, t: string): XmlNode =
    for el in preorder(tree):
        if el.tag == t:
            return el


proc key*(s: string): array[5, byte] =
    case s.len
        of 0: result = default(array[5, byte])
        else:
            let ln = s.len
            result = cast[array[5, byte]]([s[0], s[ln /% 4], s[ln /% 3], s[ln /% 2], s[ln - 1]])


proc getParam*(q: string, param: string): string =
    for (k, v) in q.decodeQuery():
        if k == param:
            return v

proc mergeUri*(dst: ref Uri, src: Uri): ref Uri =
    ## Assign parts of `src` Uri over to `dst` Uri.
    type UrifIelds = enum scheme, username, password, hostname, port, path
    template take(field) =
        shallowCopy dst.field, src.field
    take scheme
    take username
    take password
    take hostname
    take port
    take path
    var query = initTable[string, string]()
    for (k, v) in dst.query.decodeQuery:
        query[k] = v
    for (k, v) in src.query.decodeQuery:
        query[k] = v
    dst.query = encodeQuery(collect(for k, v in query.pairs(): (k, v)))
    # dst.query = encodeQuery(convert(seq[(string, string)], query))
    dst.anchor = src.anchor
    dst.opaque = src.opaque
    # FIXME: should this be assigned ?
    # src.isIpv6 = dst.isIpv6
    dst

proc `==`*(a: string, b: XmlNode): bool {.inline.} = a == b.tag
proc `==`*(a: XmlNode, b: string): bool {.inline.} = b == a

proc `add`*(n: XmlNode, s: string) = n.add newText(s)

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

proc last*(node: VNode, kind: VNodeKind): VNode =
    for n in node.preorder():
        if n.kind == kind:
            return n
    return node

proc clear*(node: VNode) =
    privateAccess(VNode)
    node.kids.setlen(0)
    node.attrs.setlen(0)

proc clearAttrs*(node: VNode) {.inline.} =
    privateAccess(VNode)
    node.attrs.setlen(0)

proc clearChildren*(node: VNode) {.inline.} =
    privateAccess(VNode)
    node.kids.setlen(0)

proc clear*(node: XmlNode) {.inline.} =
    privateAccess(XmlNode)
    node.s.setLen 0

proc delAttr*(n: VNode, k: auto) =
    privateAccess(VNode)
    for i in countup(0, n.attrs.len-2, 2):
        if n.attrs[i] == k:
            n.attrs.del(i)
            n.attrs.del(i+1)

proc lenAttr*(n: VNode): int =
    privateAccess(VNode)
    n.attrs.len /% 2

iterator flatorder*(tree: var XmlNode): XmlNode {.closure, gcsafe.} =
    for el in mitems(tree):
        if len(el) > 0:
            let po = flatorder
            for e in po(el):
                yield e
        yield el

iterator filter*(tree: var XmlNode, tag = "", kind = xnElement): XmlNode {.gcsafe.} =
    if kind == xnElement:
        for node in tree.flatorder():
            if node.kind == xnElement and (tag == "" or node.tag == tag):
                yield node
    else:
        for node in tree.flatorder():
            if node.kind == kind:
                yield node




iterator vflatorder*(tree: VNode): VNode {.closure.} =
    for el in items(tree):
        if len(el) > 0:
            {.cast(gcsafe).}:
                let po = vflatorder
                for e in po(el):
                    yield e
        yield el


proc first*(node: VNode, kind: VNodeKind): VNode {.gcsafe.} =
    for n in node.vflatorder():
        if n.kind == kind:
            return n
    return node

proc hasAttr*(el: VNode, k: string): bool =
    for (i, v) in el.attrs:
        if k == i:
            return true
    return false

template find*(node: VNode, kind: VNodeKind): VNode = first(node, kind)
proc find*(node: VNode, kind: VNodeKind, attr: (string, string)): VNode =
    for n in node.vflatorder():
        if n.kind == kind and
        n.hasAttr(attr[0]) and
        n.getAttr(attr[0]) == attr[1]:
            return n
    return node

proc initStyle*(path: string): VNode =
    result = newVNode(VNodeKind.style)
    result.add newVNode(VNodeKind.text)
    result[0].text = readFile(path)

proc initStyleStr*(s: sink string): VNode =
    result = newVNode(VNodeKind.style)
    result.add newVNode(VNodeKind.text)
    result[0].text = s

proc xmlHeader*(version: static[string] = "1.0", encoding: static[string] = "UTF-8"): string =
    fmt"""<?xml version="{version}" encoding="{encoding}" ?>"""

proc toXmlString*(node: XmlNode): string =
    result.add xmlHeader()
    result.add "\n"
    result.add $node

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

{.push inline.}

proc hasAttr*(el: XmlNode, k: string): bool = (not el.attrs.isnil) and el.attrs.haskey k
proc getAttr*(el: XmlNode, k: string): lent string = el.attrs[k]
proc getAttr*(el: XmlNode, k: string, v: string): string =
    if el.hasAttr(k):
        el.getAttr(k)
    else:
        v
proc setAttr*(el: XmlNode, k: string, v: sink auto) = el.attrs[k] = v
proc findclass*(tree: XmlNode, cls: string): XmlNode =
    for el in preorder(tree):
        if el.kind == xnElement and cls in el.getAttr("class", ""):
            return el
{.pop inline.}

import std/[macros, genasts]

macro threadVars*(args: varargs[untyped]) =
    result = newStmtList()
    for i, arg in args:
        for name in arg[0..^2]:
            result.add:
                genast(name, typ = arg[^1]):
                    var name {.threadVar.}: typ

macro pragmaVars*(tp, pragma: untyped, vars: varargs[untyped]): untyped =
    ## Apply a pragma to multiple variables (push/pop doesn't work in nim 1.6.4)
    let prg = nnkPragma.newTree(pragma)
    let idefs = nnkIdentDefs.newTree()
    for varIdent in vars:
        idefs.add nnkPragmaExpr.newTree(
            varIdent,
            prg
        )
    idefs.add tp
    idefs.add newEmptyNode()
    result = nnkVarSection.newTree(idefs)

proc sre*(pattern: static string): Regex {.gcsafe.} =
    ## Static regex expression
    var rx {.threadvar.}: Regex
    rx = re(pattern)
    return rx


type Link* = enum canonical, stylesheet, amphtml, jscript = "script", alternate
type LDjson* = enum ldjson = "application/ld+json"

proc isLink*(el: VNode, tp: Link): bool {.inline.} = el.getAttr("rel") == $tp

proc isSomething*(s: string): bool {.inline.} = not s.isEmptyOrWhitespace
proc something*[T](arr: varargs[T]): T =
    for el in arr:
        if el != default(T):
            return el

proc replaceTilNoChange(input: var auto, pattern, repl: auto): string =
    while pattern in input:
        input = input.replace(pattern, repl)
    input


pragmaVars(Regex, threadvar, sentsRgx1, sentsRgx2, sentsRgx3, sentsRgx4, sentsRgx5, sentsRgx6,
        sentsRgx7, sentsRgx8, sentsRgx9, sentsRgx10, sentsRgx11, sentsRgx12, sentsRgx13, sentsRgx14,
        sentsRgx15, sentsRgx16, sentsRgx17, sentsRgx18, sentsRgx19, sentsRgx20, sentsRgx21,
        sentsRgx22, sentsRgx23, sentsRgx24, sentsRgx25, sentsRgx26, sentsRgx27, sentsRgx28,
        sentsRgx29, sentsRgx30, sentsRgx31, sentsRgx32, sentsRgx33, sentsRgx34, sentsRgx35,
        sentsRgx36, sentsRgx37, sentsRgx38, sentsRgx39, sentsRgx40, sentsRgx41, sentsRgx42,
        sentsRgx43, sentsRgx44, sentsRgx45, sentsRgx46, sentsRgx47, sentsRgx48, sentsRgx49,
        sentsRgx50, sentsRgx51, sentsRgx52, sentsRgx53, sentsRgx54)

proc initSentsRgx*() =
    if sentsRgx1.isnil:
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

proc readBytes*(f: string): seq[uint8] =
    let s = open(f)
    defer: s.close()
    result.setLen(s.getFileSize())
    discard readBytes(s, result, 0, result.len)

proc toString*(bytes: openarray[byte | char]): string =
    result = newString(bytes.len)
    copyMem(result[0].addr, bytes[0].unsafeAddr, bytes.len)

template toOA*(p: ptr uint8, len: int): openarray[byte] =
    let ua = cast[ptr UncheckedArray[byte]](p)
    ua.toOpenArray(0, len - 1)

proc toString*(p: ptr uint8, len: int): string =
    p.toOA(len).toString

import unicode
const stripchars = ["-".runeAt(0), "_".runeAt(0)]
proc slugify*(value: string): string =
    ## Slugifies an unicode string

    result = toNFKC(value).toLower()
    result = result.replace(sre("[^\\w\\s-]"), "")
    result = result.replace(sre("[-\\s]+"), "-").strip(runes = stripchars)

var uriVar {.threadVar.}: URI
proc rewriteUrl*(el, rewrite_path: auto, hostname = WEBSITE_DOMAIN) =
    parseURI(string(el.getAttr("href")), uriVar)
    # remove initial dots from links
    uriVar.path = uriVar.path.replace(sre("^\\.?\\.?"), "")
    if uriVar.hostname == "" or (uriVar.hostname == hostname and
        uriVar.path.startsWith("/")):
        uriVar.path = joinpath(rewrite_path, uriVar.path)
    el.setAttr("href", $uriVar)
    # debug "old: {prev} new: {$uriVar}, {rewrite_path}"

import chronos
import faststreams/inputs
proc readFileAsync*(file: string): Future[string] {.async.} =
    var data: seq[byte]
    let handler = memFileInput(file)
    data.setLen(handler.s.len.get())
    discard Async(handler).readInto(data)
    return data.toString

