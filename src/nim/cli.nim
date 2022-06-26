import os,
       uri,
       std/enumerate,
       nimpy {.all.},
       cligen,
       strformat
import
    cfg,
    types,
    server_types,
    server_tasks,
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
        deletePage(relpath)

proc clearPageCache(force=false) =
    # Clear page cache database
    if force or os.getenv("DO_SERVER_CLEAR", "") == "1":
        echo fmt"Clearing pageCache at {pageCache[].path}"
        pageCache[].clear()
    else:
        echo "Ignoring doclear flag because 'DO_SERVER_CLEAR' env var is not set to '1'."

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
    dispatchMulti([start], [clearPage], [cliPubTopic], [cliReindexSearch], [clearSource], [clearPageCache])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)
