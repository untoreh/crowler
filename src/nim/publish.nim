import nimpy
import cfg
import os
import sequtils
import tables
import json
import sugar
import html
import times
import types
import strutils

let machinery = pyImport("importlib.machinery")

proc relimport(relpath: string): PyObject =
    let abspath = os.expandFilename(relpath & ".py")
    let loader = machinery.SourceFileLoader("config", abspath)
    return loader.load_module("config")

let pycfg = relimport("../py/config")
let ut = relimport("../py/utils")

proc publish(topic="vps", n=3): seq[Article] =
    let grp = ut.zarr_articles_group(topic)
    let arts = grp["articles"]
    let a = new(Article)
    var data: PyObject
    let curtime = getTime()
    var parsed: seq[Article]
    for i in 1..n:
        data = arts[i]
        a.title = pyget(data["title"], "")
        a.desc = pyget(data["description"], "")
        a.content = pyget(data["maintext"], "")
        a.author = pyget(data["authors"], @[""]).join(", ")
        # echo data["date_publish"].to(nil)
        a.pubDate = pydate(data["date_publish"], curtime)
        a.modDate = curtime
        a.imageUrl = pyget(data["image_url"], "")
        parsed.add(deepCopy(a))
    return parsed

# for x in grp:
#     let j = grp[x][0].to(JsonNode)
#     let x = collect(newSeq):
#         for k in keys(j): k
#     echo x

when isMainModule:
    let aa = publish(topic="vps")
    echo len(aa)
    echo aa[0]
    echo aa[1]
    echo aa[2]

    # var path = joinPath(SITE_PATH, "index.html")
    # writeFile(path, &("<!doctype html>\n{buildPage()}"))
