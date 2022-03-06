import nimpy
import cfg
import os
# import sequtils
# import tables
# import json
import sugar
import html
import times
import types
import strutils
import timeit
import strformat
import algorithm

let machinery = pyImport("importlib.machinery")

proc relimport(relpath: string): PyObject =
    let abspath = os.expandFilename(relpath & ".py")
    let loader = machinery.SourceFileLoader("config", abspath)
    return loader.load_module("config")

let pycfg = relimport("../py/config")
let ut = relimport("../py/utils")
const emptyseq: seq[string] = @[]

proc getarticles(topic: string, n=3, doresize=false): seq[Article] =
    let grp = ut.zarr_articles_group(topic)
    var a: Article
    let arts = grp["articles"]
    assert pyiszarray(arts)
    var data: PyObject
    let curtime = getTime()
    var parsed: seq[Article]
    var done: seq[PyObject]
    let h = arts.shape[0].to(int)
    var msg: string
    let m = min(n, h)
    if m != 0:
        msg = &"getting {m} articles from {h} available ones for topic {topic}."
    else:
        msg = &"No articles were found for topic {topic}."
    logger.log(lvlInfo, msg)
    for i in h-m..h-1:
        data = arts[i]
        a = new(Article)
        a.title = pyget(data, "title")
        a.desc = pyget(data, "desc")
        a.content = pyget(data, "content")
        a.author = pyget(data, "author")
        a.pubDate = pydate(data.get("pubDate"), curtime)
        a.imageUrl = pyget(data, "imageUrl")
        a.icon = pyget(data, "icon")
        a.url = pyget(data, "url")
        a.slug = pyget(data, "slug")
        a.lang = pyget(data, "lang")
        a.topic = pyget(data, "topic")
        a.tags = pyget(data, "tags", emptyseq)
        parsed.add(a)
        done.add(data)
    if doresize:
        discard ut.save_topic(topic, done, m)
    return parsed

proc getSubDirs(path: string): seq[int] =
    var result = collect(for f in walkDirs(path / "*"):
                try: parseInt(lastPathPart(f)) except: -1 )
    sort(result)
    result

proc countDirFiles(path: string): int =
    len(collect(for f in walkFiles(path / "*"): f))

proc getSubdirNumber(topic: string, iter: int): int =
    let topic_path = SITE_PATH / topic
    if iter == 0:
        try:
            var dirs = getSubDirs(topic_path)
            let topdir = $max(1, dirs.high)
            var i: int
            for d in dirs:
                i = d
                # NOTE: we don't consider how many articles are in a batch
                # so this is a soft limit
                if countDirFiles(topic_path / $d) < MAX_DIR_FILES:
                   return d
            return i + 1
        except ValueError:
            return 1

proc ensureDir(dir: string) =
    if not dirExists(dir):
        if fileExists(dir):
            logger.log(lvlinfo, "Deleting file that should be a directory " & dir)
            removeFile(dir)
        logger.log(lvlInfo, "Creating directory " & dir)
        createDir(dir)

proc publish(topic: string, arts: seq[Article], iter: int = 0) =
    ##  Generates html for a list of `Article` objects and writs to file.
    let subdir = getSubdirNumber(topic, iter)
    let basedir = SITE_PATH / topic / $subdir

    ensureDir(basedir)
    for a in arts:
        buildPost(basedir, a)

when isMainModule:
    let topic = "vps"
    let arts = getarticles(topic, doresize=false)
    publish(topic, arts)

    # var path = joinPath(SITE_PATH, "index.html")
    # writeFile(path, &("<!doctype html>\n{buildPost()}"))
