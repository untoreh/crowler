import nimpy, options, nre, strutils, strformat, os, std/enumerate
import cfg, quirks, utils

const
    rxend = "(?=/|$)"
    rxAmp = fmt"(/amp{rxend})"
    rxLang = "(/[a-z]{2}(?:-[A-Z]{2})?" & fmt"{rxend})" # split to avoid formatting regex `{}` usage
    rxTopic = fmt"(/.*?{rxend})"
    rxPage = fmt"(/(?:[0-9]+|s|g){rxend})"
    rxArt = fmt"(/.*?{rxend})"
    rxPath = fmt"{rxAmp}?{rxLang}?{rxTopic}?{rxPage}?{rxArt}?"

type UriTuple = (string, string, string, string, string)
type UriCaptures* = tuple[amp, lang, topic, page, art: string]
proc uriTuple*(match: seq[Option[string]]): UriCaptures =
    var i = 0
    for v in result.fields:
        v = match[i].get("")
        v.removePrefix("/")
        i += 1

proc uriTuple*(relpath: string): UriCaptures =
    let m = relpath.match(sre rxPath).get
    result = m.captures.toSeq.uriTuple

proc join*(tup: UriCaptures, sep="/", n=0): string =
    var s: seq[string]
    s.setLen 5-n
    var c = 0
    for (n, v) in enumerate(tup.fields()):
        if likely(n != 0):
            s[c] = v
            c += 1
    s.join(sep)

proc fp*(relpath: string): string =
    ## Full file path
    SITE_PATH / (if relpath == "":
        "index.html"
    elif relpath.splitFile.ext == "":
        relpath & ".html"
    else: relpath)
