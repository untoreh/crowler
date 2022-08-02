import nimpy, options, nre, strutils, strformat, os, std/enumerate, std/mimetypes, uri, scorper/http/httpcore
import cfg, quirks, utils

const
    rxend = "(?=/|(?=[?].*)|$)"
    rxAmp = fmt"(/amp{rxend})"
    rxLang = "(/[a-z]{2}(?:-[A-Z]{2})?" & fmt"{rxend})" # split to avoid formatting regex `{}` usage
    rxTopic = fmt"(/.*?{rxend})"
    rxPage = fmt"(/(?:[0-9]+|s|g|feed\.xml|sitemap\.xml){rxend})"
    rxArt = fmt"(/.*?{rxend})"
    rxPath = fmt"{rxAmp}?{rxLang}?{rxTopic}?{rxPage}?{rxArt}?"

const defaultHeaders = @["Cache-Control: no-store"]

type UriTuple = (string, string, string, string, string)
type UriCaptures* = tuple[amp, lang, topic, page, art: string]
proc mUriCaptures*(): var UriCaptures =
    ## Create an empty `UriCaptures` mutable variable.
    result = new(UriCaptures)[]
proc uriTuple*(match: seq[Option[string]]): UriCaptures =
    var i = 0
    for v in result.fields:
        v = match[i].get("")
        v.removePrefix("/")
        i += 1

proc uriTuple*(relpath: string): UriCaptures =
    let m = relpath.match(sre rxPath).get
    result = m.captures.toSeq.uriTuple

proc join*(tup: UriCaptures, sep = "/", n = 0): string =
    var s: seq[string]
    s.setLen 5-n
    var c = 0
    for (n, v) in enumerate(tup.fields()):
        if likely(n != 0):
            s[c] = v
            c += 1
    s.join(sep)

proc suffixPath*(relpath: string): string =
    var relpath = relpath
    relpath.removeSuffix("/")
    if relpath == "":
        "index.html"
    elif relpath.splitFile.ext == "":
        relpath & ".html"
    else: relpath

proc fp*(relpath: string): string =
    ## Full file path
    # NOTE: Only Unix paths make sense! because `/` operator would output `\` on windows
    SITE_PATH / relpath.suffixPath()

var mimes {.threadvar.}: MimeDB
proc mimePath*(url: string): string {.gcsafe.} =
    let ext = url.splitFile.ext
    let mimetype = getMimetype(
        mimes,
        if ext.len > 0: ext[1..^1]
        else: ""
    )
    mimetype


proc initMimes*() =
    mimes = newMimetypes()

proc format*(headers: seq[string]): string =
    for h in headers[0..^2]:
        result.add h & "\c\L"
    result.add headers[^1]

when declared(httpbeast):
    import tables
    proc format*(headers: HttpHeaders): string =
        for (k, v) in headers.pairs():
            result.add k & ":" & v.join() & httpNewLine
        result.stripLineEnd

type Header* = enum
    hcontent = "Content-Type"
    haccept = "Accept"
    hencoding = "Content-Encoding"
    hlang = "Accept-Language"
    hetag = "ETag"
    hloc = "Location"

# proc add*(h: Header, v: string) = baseHeaders.add $h & ": " & v

# proc addHeaders*(headers: seq[(Header, string)]) =
#     for (h, s) in headers:
#         h.add(s)

when isMainModule:
    initMimes()
    # var s = @[""]
    # mimeHeader("asd.json", s)
    # echo s
