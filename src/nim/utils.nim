import os
import sets
import cfg
import sugar
import deques
import re
import strutils
import strformat
import xmltree
import translate_types
import strtabs
import macros
import locks
import weave
export weave

var loggingLock: Lock
initLock(loggingLock)

macro `debug`*(code: untyped): untyped =
    if logLevelMacro != lvlNone:
        quote do:
            withLock(loggingLock):
                logger[].log lvlDebug, fmt"{getThreadId(Weave)} - " & fmt `code`
    else:
        quote do:
            discard

macro `warn`*(code: untyped): untyped =
    quote do:
        loggingLock.acquire()
        logger[].log lvlWarn, fmt `code`
        loggingLock.release()

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
            el.text
        else:
            el.attrs.getOrDefault("alt",
                                  el.attrs.getOrDefault("title"))

proc setText*(el, v: auto) =
    case el.kind:
        of xnText, xnVerbatimText:
            el.text = v
        else:
            if hasKey(el.attrs, "alt"):
                el.attrs["alt"] = v
            else:
                el.attrs["title"] = v

proc replaceTilNoChange(input: var auto, pattern, repl: auto): string =
    while pattern in input:
        input = input.replace(pattern, repl)
    input

proc splitSentences*(text: string): seq[string] =
    var sents = text.replace(re"([?!.])\s", "$1\n")
    sents = sents.replace(re"\r", "")
    sents = sents.replace(re"\b([a-z]+\?) ([A-Z][a-z]+)\b", "$1\n$2")
    sents = sents.replace(re"\b([a-z]+ \.) ([A-Z][a-z]+)\b", "$1\n$2")
    sents = sents.replace(re"\n([.!?]+)\n", "$1\n")

    sents = replaceTilNoChange(sents, re"\[([^\[\]\(\)]*)\n([^\[\]\(\)]*)\]", "[$1 $2]")
    sents = replaceTilNoChange(sents, re"\(([^\[\]\(\)]*)\n([^\[\]\(\)]*)\)", "[$1 $2]")

    sents = replaceTilNoChange(sents, re"\[([^\[\]]{0,250})\n([^\[\]]{0,250})\]", "[$1 $2]")
    sents = replaceTilNoChange(sents, re"\(([^\(\)]{0,250})\n([^\(\)]{0,250})\)", "($1 $2)")

    sents = replaceTilNoChange(sents, re"\[((?:[^\[\]]|\[[^\[\]]*\]){0,250})\n((?:[^\[\]]|\[[^\[\]]*\]){0,250})\]", "[$1 $2]")
    sents = replaceTilNoChange(sents, re"\(((?:[^\(\)]|\([^\(\)]*\)){0,250})\n((?:[^\(\)]|\([^\(\)]*\)){0,250})\)", "($1 $2)")

    sents = replace(sents, re"\.\n([a-z]{3}[a-z-]{0,}[ \.\:\,])", ". $1")

    sents = replace(sents, re"(\b[A-HJ-Z]\.)\n", "$1 ")

    sents = replace(sents, re"\n(and )", " $1")
    sents = replace(sents, re"\n(or )", " $1")
    sents = replace(sents, re"\n(but )", " $1")
    sents = replace(sents, re"\n(nor )", " $1")
    sents = replace(sents, re"\n(yet )", " $1")
    # or IN. (this is nothing like a "complete" list...)
    sents = replace(sents, re"\n(of )", " $1")
    sents = replace(sents, re"\n(in )", " $1")
    sents = replace(sents, re"\n(by )", " $1")
    sents = replace(sents, re"\n(as )", " $1")
    sents = replace(sents, re"\n(on )", " $1")
    sents = replace(sents, re"\n(at )", " $1")
    sents = replace(sents, re"\n(to )", " $1")
    sents = replace(sents, re"\n(via )", " $1")
    sents = replace(sents, re"\n(for )", " $1")
    sents = replace(sents, re"\n(with )", " $1")
    sents = replace(sents, re"\n(that )", " $1")
    sents = replace(sents, re"\n(than )", " $1")
    sents = replace(sents, re"\n(from )", " $1")
    sents = replace(sents, re"\n(into )", " $1")
    sents = replace(sents, re"\n(upon )", " $1")
    sents = replace(sents, re"\n(after )", " $1")
    sents = replace(sents, re"\n(while )", " $1")
    sents = replace(sents, re"\n(during )", " $1")
    sents = replace(sents, re"\n(within )", " $1")
    sents = replace(sents, re"\n(through )", " $1")
    sents = replace(sents, re"\n(between )", " $1")
    sents = replace(sents, re"\n(whereas )", " $1")
    sents = replace(sents, re"\n(whether )", " $1")

    # no sentence breaks in the middle of specific abbreviations
    sents = replace(sents, re"(\be\.)\n(g\.)", "$1 $2")
    sents = replace(sents, re"(\bi\.)\n(e\.)", "$1 $2")
    sents = replace(sents, re"(\bi\.)\n(v\.)", "$1 $2")

    # no sentence break after specific abbreviations
    sents = replace(sents, re"(\be\. ?g\.)\n", "$1 ")
    sents = replace(sents, re"(\bi\. ?e\.)\n", "$1 ")
    sents = replace(sents, re"(\bi\. ?v\.)\n", "$1 ")
    sents = replace(sents, re"(\bvs\.)\n", "$1 ")
    sents = replace(sents, re"(\bcf\.)\n", "$1 ")
    sents = replace(sents, re"(\bDr\.)\n", "$1 ")
    sents = replace(sents, re"(\bMr\.)\n", "$1 ")
    sents = replace(sents, re"(\bMs\.)\n", "$1 ")
    sents = replace(sents, re"(\bMrs\.)\n", "$1 ")

    sents.split(re"\n")
