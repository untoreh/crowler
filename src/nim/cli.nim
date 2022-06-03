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

template deleteArt() {.dirty.} =
    let
        artPath = getArticlePath(capts)
        fpath = SITE_PATH / artPath
    doassert capts.topic != ""
    doassert capts.art != ""
    doassert capts.page != ""
    pageCache[].del(fpath)
    pageCache[].del(SITE_PATH / "amp" / artPath)
    for lang in TLangsCodes:
        pageCache[].del(SITE_PATH / "amp" / lang / artPath)
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

proc clearPage*(url: string) =
    initThread()
    let
        relpath = url.parseUri.path
        capts = uriTuple(relpath)
    if capts.art != "":
        deleteArt()
    else:
        let fpath = SITE_PATH / relpath
        pageCache[].del(fpath)
        pageCache[].del(SITE_PATH / "amp" / relpath)
        for lang in TLangsCodes:
            pageCache[].del(SITE_PATH / "amp" / lang / relpath)
            pageCache[].del(SITE_PATH / lang / relpath)


proc cliPubTopic(topic: string) =
    initThread()
    pubTopic(topic)

when isMainModule:
    dispatchMulti([start], [clearPage], [cliPubTopic])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)
