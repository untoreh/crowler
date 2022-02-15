import macros,
       macroutils,
       os,
       streams,
       parsexml,
       strutils,
       karax / [karaxdsl, vdom, vstyles],
       unicode

const cfg_path = currentSourcePath().splitPath()[0]

const
    PROJECT_PATH* = joinPath(cfg_path, "..", "..")
    WEBSITE_TITLE* = "wsl"
    SITE_PATH* = joinpath(PROJECT_PATH, "site")
    ASSETS_PATH* = os.joinPath(SITE_PATH, "assets")
    # TPL_PATH* = os.joinPath(SITE_PATH, "templates")

block:
    var filename = joinpath(PROJECT_PATH, "src", "logo.svg")
    var s = newFileStream(filename, fmRead)
    if s == nil: quit("cannot open the file " & filename)
    var x: XmlParser
    open(x, s, filename)
    var node: VNode
    # var parts: seq[string] = @[]
    while true:
        x.next
        case x.kind
        of xmlElementOpen:
            echo x.elementName
            node = tree(parseEnum[VNodeKind](x.elementName))
        of xmlAttribute:
            # setAttr(node, x.attrKey, x.attrValue)
            discard
        of xmlElementEnd:
            echo "ASDSA"
            # echo node.kind
            # if x.elementName == node.kind
            # nodes
        of xmlEof:
            break
        else:
            discard

echo "done"
quit()
