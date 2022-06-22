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
    publish,
    stats,
    search


proc clearPage*(url: string) =
    initThread()
    let
        relpath = url.parseUri.path
        capts = uriTuple(relpath)
    if capts.art != "":
        deleteArt(capts)
    else:
        let fpath = SITE_PATH / relpath
        pageCache[].del(fpath)
        pageCache[].del(SITE_PATH / "amp" / relpath)
        for lang in TLangsCodes:
            pageCache[].del(SITE_PATH / "amp" / lang / relpath)
            pageCache[].del(SITE_PATH / lang / relpath)

import topics, uri
proc clearSource(domain: string) =
    initThread()
    for topic in topicsCache.keys:
        for pn in 0..lastPageNum(topic):
            let arts = getDoneArticles(topic, pn)
            for ar in arts:
                if parseUri(ar.url).hostname == domain:
                    let capts = uriTuple("/" & topic & "/" & $pn & "/" & ar.slug)
                    deleteArt(capts)

proc cliPubTopic(topic: string) =
    initThread()
    discard pubTopic(topic)

proc cliReindexSearch() =
    initThread()
    pushAllSonic(clear=true)

when isMainModule:
    dispatchMulti([start], [clearPage], [cliPubTopic], [cliReindexSearch], [clearSource])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)
