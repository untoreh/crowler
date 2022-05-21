import os,
       uri,
       std/enumerate,
       nimpy {.all.},
       cligen
import
    cfg,
    types,
    server_types,
    translate_types,
    cache,
    articles,
    topics,
    server,
    publish

proc clearPage*(url: string) =
    let
        relpath = url.parseUri.path
        capts = uriTuple(relpath)
        artPath = getArticlePath(capts)
        fpath = SITE_PATH / artPath
    doassert capts.topic != ""
    doassert capts.art != ""
    doassert capts.page != ""
    pageCache[].del(fpath)
    pageCache[].del(SITE_PATH / capts.amp / artPath)
    for lang in TLangsCodes:
        pageCache[].del(SITE_PATH / capts.amp / lang / artPath)
        pageCache[].del(SITE_PATH / lang / artPath)
    let tg = topicsCache.fetch(capts.topic).group
    let pageArts = tg[$topicData.done][capts.page]
    let pyslug = capts.art.nimValueToPy().newPyObject
    var toRemove: seq[int]
    for (n, a) in enumerate(pageArts):
        if (not pyisnone(a)) and a["slug"] == pyslug:
            toRemove.add n
            break
    for n in toRemove:
        pageArts[n] = PyNone

when isMainModule:
    initThread()
    dispatchMulti([start], [clearPage], [pubTopic])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)
