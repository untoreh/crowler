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
       normalize,
       chronos

# import std/segfaults
# export segfaults

# import translate_types
import locktpl
lockedStore(Table)
lockedList(Deque)
import locktplutils
export nre, tables, locktplutils

static: echo "loading utils..."

template procName*(): string = strutils.split(getStacktrace())[^2]

template quitl*() =
  echo "!!!quitting!!!"
  writeStackTrace()
  echo procName()
  quit()

type kstring = string
const baseUri* = initUri()

var loggingLock: Lock
initLock(loggingLock)

macro withLocks*(l: untyped, def: untyped): untyped =
  ## Locks for definitions with a `body`
  let body = def.body
  let lockedBody = newNimNode(nnkStmtList)
  lockedBody.add quote do:
    {.locks: `l`.}:
      `body`
  def.body = lockedBody
  return def

template withAsyncLock*(l: AsyncLock, code) =
  try:
    await l.acquire()
    code
  finally:
    l.release()

template withWaitLock*(l: AsyncLock, code) =
  try:
    waitFor l.acquire()
    code
  finally:
    l.release()


template lgetOrPut*[T, K](c: T, k: K, v: untyped): untyped =
  ## Lazy `mgetOrPut`
  # mixin get, put
  try:
    c.get(k)
  except KeyError:
    c.put(k, v)

template lcheckOrPut*[T, K](c: T, k: K, v: untyped): untyped =
  ## Lazy `mgetOrPut`
  # mixin get, contains, put, `[]`, `[]=`
  if k in c:
    c[k]
  else:
    c[k] = v
    c[k]

template alcheckOrPut*[T, K](c: T, k: K, v: untyped): untyped {.dirty.} =
  ## Lazy async `mgetOrPut`
  # mixin get, contains, put, `[]`, `[]=`
  if (await (k in c)):
    await c[k]
  else:
    await c.put(k, v)
    await c[k]

template logstring(code: untyped): untyped =
  when not compileOption("threads"):
    procName() & " " & fmt code
  else:
    let tid {.inject.} = getThreadId()
    fmt"{tid} - " & fmt code

const shouldLog = logLevelMacro == lvlAll or (not defined(release))

template logexc*() {.dirty.} =
  bind shouldLog, logLevelMacro, lvlDebug, loggingLock, logger, log
  when shouldLog and logLevelMacro <= lvlDebug:
    block:
      let excref = getCurrentException()
      withLock(loggingLock):
        if not excref.isnil:
          let exc = excref[]
          logger[].log lvlDebug, $exc

template debug*(code: untyped; dofmt = true): untyped =
  when shouldLog and logLevelMacro <= lvlDebug:
    withLock(loggingLock):
      logger[].log lvlDebug, when dofmt: logstring(`code`) else: `code`

template logall*(code: untyped): untyped =
  when shouldLog and logLevelMacro < lvlNone:
    withLock(loggingLock):
      logger[].log lvlAll, logstring(`code`)


template sdebug*(code) =
  try: debug code
  except Exception: discard

template qdebug*(code) =
  try: debug code
  except: quitl()

template warn*(code: untyped): untyped =
  when logLevelMacro <= lvlWarn:
    withLock(loggingLock):
      logger[].log lvlWarn, logstring(`code`)

template swarn*(code) =
  try: warn code
  except Exception: discard

template info*(code: untyped): untyped =
  when logLevelMacro <= lvlInfo:
    withLock(loggingLock):
      logger[].log lvlInfo, logstring(`code`)

macro checkNil*(v; code: untyped): untyped =
  let name =
    case v.kind:
      of nnkDotExpr: $(v[^1])
      else: $v

  let message = fmt"{`name`} cannot be nil"
  quote do:
    if `v`.isnil:
      debug `message`
      raise newException(ValueError, `message`)
    else:
      `code`

template checkNil*(v) = checkNil(v): discard

template checkNil*(v; msg: string) = checkNil(v, msg): discard

macro checkNil*(v; msg: string, code: untyped): untyped =
  quote do:
    if `v`.isnil:
      debug `msg`, false
      raise newException(ValueError, `msg`)
    else:
      `code`

template setNil*(id, val) =
  if id.isnil:
    id = val

template ifNil*(id, val) =
  if id.isnil:
    val

template notNil*(id, val) =
  if not id.isnil:
    val

template maybeCreate*(id, tp; force: static[bool] = false) =
  when force:
    id = create(tp)
  else:
    if id.isnil:
      id = create(tp)
  reset(id[])

proc free*[T](o: ptr[T]) {.inline.} =
  if not o.isnil:
    reset(o[])
    dealloc(o)

proc maybeFree*[T](o: ptr[T]) {.inline.} =
  if not getCurrentException().isnil:
    free(o)

template checkTrue*(stmt: untyped, msg: string) =
  if not (stmt):
    raise newException(ValueError, msg)

proc `!!`*(stmt: bool) {.inline.} =
  const loc = fmt"{instantiationInfo().filename}:{instantiationInfo().line}"
  const message = fmt"Statement at {loc} was false!"
  if not stmt:
    raise newException(ValueError, message)

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

let regexTable = initLockTable[string, Regex]()
proc get*(t: LockTable[string, Regex], k: string): Regex = t[k]
proc put*(t: LockTable[string, Regex], k: string, v: Regex): Regex = (t[k] = v; v)
proc sre*(pattern: static[string]): Regex {.gcsafe, inline.} =
  ## Cached regex expression (should be replaced by compile time nim-regex)
  lgetOrPut(regexTable, pattern):
    re(pattern)

type StringSet = HashSet[string]

converter asStringSet(v: openarray[string]): StringSet = to_hashset[string](v)
const exts = [".htm", ".html"]

proc fileExtension(path: string): string {.inline.} =
  let pos = searchExtPos(path)
  if pos != -1:
    result = path[pos..^1]

iterator filterFiles*(root: string;
                   exts: Stringset = exts.asStringSet;
                   exclDirs: StringSet = [];
                   topDirs: StringSet = [];
                  ): string {.closure.} =
  ## A directory iterator:
  ## `exts`: which file extensions should be included
  ## `exclDirs`: directory names that are skipped on every node (blacklist)
  ## `topDirs`: directory names that are included only at top node (subnodes only respect `exclDirs`)
  let rootAbs = expandFilename(root)
  var
    path: string
    kind: PathComponent
    topfiles = collect:
      for p in walkDir(rootAbs):
        if p.kind == pcDir or p.kind == pcLinkToDir:
          let n = p.path.absolutePath.lastPathPart
          if (not (n in exclDirs)) and (len(topDirs) == 0 or n in topDirs):
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
      if path.lastPathPart in exclDirs:
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


const
  skip_nodes* = static(["code", "style", "script", "address", "applet", "audio", "canvas",
        "embed", "time", "video", "svg"])
  skip_class* = ["menu-lang-btn", "material-icons", "rss", "sitemap"].static
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
              let nodeClasses = node.attrs["class"].split().toHashSet
              for class in skip_class:
                if class in nodeClasses:
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
      result = cast[array[5, byte]]([s[0], s[ln /% 4], s[ln /% 3], s[ln /% 2],
          s[ln - 1]])


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

const skip_vnodes* = static([VNodeKind.code, script, VNodeKind.address, audio,
      canvas, embed, time, video, svg])
iterator preorder*(tree: VNode, withStyles: static[bool] = false): VNode =
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
        when withStyles:
          if node.kind == VNodeKind.style:
            yield node
        else:
          if node.kind == VNodeKind.style:
            continue

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

proc `attrs=`*(node: VNode, v: seq[kstring]) {.inline.} =
  privateAccess(VNode)
  node.attrs.setLen(0)
  node.attrs.add v

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
      # NOTE: the order is important here, because of how deletion happen
      n.attrs.del(i+1) # delete the key
      n.attrs.del(i) # delete the key
      break # NOTE: we assume there is only ONE instance of the attribute

proc delAttr*(n: XmlNode, k: auto) =
  if n.hasAttr(k):
    n.attrs.del(k)

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

iterator filter*(tree: var XmlNode, tag = "",
    kind = xnElement): XmlNode {.gcsafe.} =
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
      let po = vflatorder
      {.cast(gcsafe).}:
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

proc initStyle*(path: static[string]): VNode {.gcsafe.} =
  let sty {.global.} = create(string)
  if unlikely(len(sty[]) == 0):
    sty[] = readFile(path)
  result = tree(VNodeKind.style, verbatim(sty[]))

proc initStyleStr*(s: sink string): VNode =
  result = tree(VNodeKind.style, verbatim(s))

proc xmlHeader*(version: static[string] = "1.0", encoding: static[
    string] = "UTF-8"): string =
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

proc hasAttr*(el: XmlNode, k: string): bool = (not el.attrs.isnil) and
    el.attrs.haskey k
proc getAttr*(el: XmlNode, k: string): lent string = el.attrs[k]
proc getAttr*(el: XmlNode, k: string, v: string): auto =
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

import std/[genasts]

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


type Link* = enum canonical, stylesheet, amphtml, jscript = "script", alternate, preload
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

proc splitSentences*(text: string): seq[string] =
  var sents = text.replace(sre"([?!.])\s", "$1\n")
  sents = sents.replace(sre"\r", "")
  sents = sents.replace(sre"\b([a-z]+\?) ([A-Z][a-z]+)\b", "$1\n$2")
  sents = sents.replace(sre"\b([a-z]+ \.) ([A-Z][a-z]+)\b", "$1\n$2")
  sents = sents.replace(sre"\n([.!?]+)\n", "$1\n")

  sents = replaceTilNoChange(sents, sre"\[([^\[\]\(\)]*)\n([^\[\]\(\)]*)\]", "[$1 $2]")
  sents = replaceTilNoChange(sents, sre"\(([^\[\]\(\)]*)\n([^\[\]\(\)]*)\)", "[$1 $2]")

  sents = replaceTilNoChange(sents, sre"\[([^\[\]]{0,250})\n([^\[\]]{0,250})\]", "[$1 $2]")
  sents = replaceTilNoChange(sents, sre"\(([^\(\)]{0,250})\n([^\(\)]{0,250})\)", "($1 $2)")

  sents = replaceTilNoChange(sents, sre"\[((?:[^\[\]]|\[[^\[\]]*\]){0,250})\n((?:[^\[\]]|\[[^\[\]]*\]){0,250})\]", "[$1 $2]")
  sents = replaceTilNoChange(sents, sre"\(((?:[^\(\)]|\([^\(\)]*\)){0,250})\n((?:[^\(\)]|\([^\(\)]*\)){0,250})\)", "($1 $2)")

  sents = replace(sents, sre"\.\n([a-z]{3}[a-z-]{0,}[ \.\:\,])", ". $1")

  sents = replace(sents, sre"(\b[A-HJ-Z]\.)\n", "$1 ")

  sents = replace(sents, sre"\n(and )", " $1")
  sents = replace(sents, sre"\n(or )", " $1")
  sents = replace(sents, sre"\n(but )", " $1")
  sents = replace(sents, sre"\n(nor )", " $1")
  sents = replace(sents, sre"\n(yet )", " $1")
  # or IN. (this is nothing like a "complete" list...)
  sents = replace(sents, sre"\n(of )", " $1")
  sents = replace(sents, sre"\n(in )", " $1")
  sents = replace(sents, sre"\n(by )", " $1")
  sents = replace(sents, sre"\n(as )", " $1")
  sents = replace(sents, sre"\n(on )", " $1")
  sents = replace(sents, sre"\n(at )", " $1")
  sents = replace(sents, sre"\n(to )", " $1")
  sents = replace(sents, sre"\n(via )", " $1")
  sents = replace(sents, sre"\n(for )", " $1")
  sents = replace(sents, sre"\n(with )", " $1")
  sents = replace(sents, sre"\n(that )", " $1")
  sents = replace(sents, sre"\n(than )", " $1")
  sents = replace(sents, sre"\n(from )", " $1")
  sents = replace(sents, sre"\n(into )", " $1")
  sents = replace(sents, sre"\n(upon )", " $1")
  sents = replace(sents, sre"\n(after )", " $1")
  sents = replace(sents, sre"\n(while )", " $1")
  sents = replace(sents, sre"\n(during )", " $1")
  sents = replace(sents, sre"\n(within )", " $1")
  sents = replace(sents, sre"\n(through )", " $1")
  sents = replace(sents, sre"\n(between )", " $1")
  sents = replace(sents, sre"\n(whereas )", " $1")
  sents = replace(sents, sre"\n(whether )", " $1")

  # no sentence breaks in the middle of specific abbreviations
  sents = replace(sents, sre"(\be\.)\n(g\.)", "$1 $2")
  sents = replace(sents, sre"(\bi\.)\n(e\.)", "$1 $2")
  sents = replace(sents, sre"(\bi\.)\n(v\.)", "$1 $2")

  # no sentence break after specific abbreviations
  sents = replace(sents, sre"(\be\. ?g\.)\n", "$1 ")
  sents = replace(sents, sre"(\bi\. ?e\.)\n", "$1 ")
  sents = replace(sents, sre"(\bi\. ?v\.)\n", "$1 ")
  sents = replace(sents, sre"(\bvs\.)\n", "$1 ")
  sents = replace(sents, sre"(\bcf\.)\n", "$1 ")
  sents = replace(sents, sre"(\bDr\.)\n", "$1 ")
  sents = replace(sents, sre"(\bMr\.)\n", "$1 ")
  sents = replace(sents, sre"(\bMs\.)\n", "$1 ")
  sents = replace(sents, sre"(\bMrs\.)\n", "$1 ")

  sents.split(sre"\n")

proc isnull*(c: char): bool {.inline.} = c == '\0'

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

proc toString*[T](p: ptr UncheckedArray[T], len: int): string =
  p.toOpenArray(0, len - 1).toString

import unicode
const stripchars = ["-".runeAt(0), "_".runeAt(0)]
proc slugify*(value: string): string =
  ## Slugifies an unicode string

  result = toNFKC(value).toLower()
  result = result.replace(sre("[^\\w\\s-]"), "")
  result = result.replace(sre("[-\\s]+"), "-").strip(runes = stripchars)

proc hasScheme*(url: string): bool {.inline.} =
  ## Check if url string has scheme (eg. "http://") in it
  url.contains sre "^(?:(?://)|(?:https?://))"

proc withScheme*(url: string): string {.inline.} =
  ## Ensures `url` has a scheme in it
  if url.hasScheme: url
  else: "//" & url

var uriVar {.threadVar.}: URI
proc rewriteUrl*(el, rewritePath: auto, hostname = WEBSITE_DOMAIN) =
  let url = el.getAttr("href").string
  if url.len == 0:
    return
  url.parseUri(uriVar)
  # remove initial dots from links
  uriVar.path = uriVar.path.replace(sre("^\\.?\\.?"), "")
  if uriVar.hostname == "" or (uriVar.hostname == hostname and
      uriVar.path.startsWith("/")):
    uriVar.path = joinpath(rewritePath, uriVar.path)
  el.setAttr("href",
             # `parseUri` doesn't keep the scheme, if it is relative ("//")
               # so we have to add it back
    if uriVar.scheme == "" and url.hasScheme:
               "//" & $uriVar
             else:
               $uriVar)
  # debug "old: {prev} new: {$uriVar}, {rewritePath}"


# import faststreams/[inputs, outputs]
import faststreams
proc readFileImpl(handle: InputStream): seq[byte] {.fsMultiSync.} =
  defer: handle.close()
  result.setLen(cast[InputStreamHandle](handle).s.len.get())
  discard handle.readInto(result)

proc readFileAsync*(file: string): Future[string] {.async.} =
  let handle = Async memFileInput(file)
  result = (await readFileImpl(handle)).toString

proc readFileFs*(file: string): string =
  let handle = memFileInput(file)
  result = readFileImpl(handle).toString

proc writeFileImpl[T](handle: OutputStream, data: T) {.fsMultiSync.} =
  defer: handle.close
  handle.writeAndWait(data)

proc writeFileAsync*[T](path: string, data: T) {.async.} =
  let handle = Async fileOutput(path, allowAsyncOps=true)
  await writeFileImpl(handle, data)

proc writeFileFs*[T](path: string, data: T) =
  let handle = fileOutput(path, allowAsyncOps=true)
  writeFileImpl(handle, data)

proc innerText*(n: VNode): string =
  if result.len > 0: result.add '\L'
  if n.kind == VNodeKind.text:
    result.add n.text
  else:
    if n.text.len > 0:
      result.add n.text
    for child in items(n):
      result.add innerText(child)

# import std/[xmltree, strtabs, strutils]
import std/htmlparser
proc toXmlNode*(el: VNode): XmlNode =
  case el.kind:
    of VNodeKind.verbatim:
      parseHtml(el.text)
    of VNodeKind.text:
      newText(el.text)
    else:
      let xAttrs = @[].toXmlAttributes
      for k, v in el.attrs:
        xAttrs[k] = v
      var kids: seq[XmlNode]
      if el.len > 0:
        for k in el:
          kids.add k.toXmlNode
      newXmlTree($el.kind, kids, attributes = xAttrs)

proc emptyVNode*(y: static[bool] = true): VNode = newVNode(VNodeKind.text)

import std/unidecode
proc toVNode*(el: XmlNode): VNode =
  privateAccess(VNode)
  try:
    case el.kind:
      of xnElement:
        let kind = parseEnum[VNodeKind](el.tag)
        var vnAttrs: seq[(string, string)]
        if not el.attrs.isnil:
          for k, v in el.attrs:
            vnAttrs.add (k, v)
        case kind:
          of VNodeKind.script, VNodeKind.style:
            let node = tree(kind, vnAttrs)
            node.value = el.innerText
            node
          else:
            var kids: seq[VNode]
            if el.len > 0:
              for k in el:
                kids.add k.toVNode
            tree(kind, vnAttrs, kids)
      of xnText:
        vn(el.text)
      else:
        verbatim($el)
  except ValueError: # karax doesn't support the node tag
    verbatim($el)

from karax/vdom {.all.} import toStringAttr
proc raw*(n: VNode, indent = 0): string =
  ## Get the wrapped and un-escaped content of node as string.
  case n.kind:
    of VNodeKind.text, VNodeKind.verbatim:
      result.add n.text
    else:
      if n.kind in {VNodeKind.style, VNodeKind.script}:
        if n.text.len == 0:
          return
      for i in 1..indent: result.add ' '
      if result.len > 0: result.add '\L'
      result.add "<" & $n.kind
      toStringAttr(id)
      toStringAttr(class)
      for k, v in attrs(n):
        result.add " " & $k & " = " & $v
      result.add ">\L"
      if n.text.len > 0:
        result.add n.text
      for child in items(n):
        result.add raw(child, indent+2)
      for i in 1..indent: result.add ' '
      result.add "\L</" & $n.kind & ">"

import zstd / [compress, decompress]
type
  CompressorObj = object of RootObj
    zstd_c: ptr ZSTD_CCtx
    zstd_d: ptr ZSTD_DCtx
  Compressor = ptr CompressorObj

when defined(gcDestructors):
  proc `=destroy`*(c: var CompressorObj) {.nimcall.} =
    if not c.zstd_c.isnil:
      discard free_context(c.zstd_c)
    if not c.zstd_d.isnil:
      discard free_context(c.zstd_d)

let comp = create(CompressorObj)
comp.zstd_c = new_compress_context()
comp.zstd_d = new_decompress_context()

proc compress*[T](v: T): seq[byte] = compress(comp.zstd_c, v, level = 2)
proc decompress*[T](v: sink seq[byte]): T = cast[T](decompress(comp.zstd_d, v))
proc decompress*[T](v: sink string): T = cast[T](decompress(comp.zstd_d, v))
