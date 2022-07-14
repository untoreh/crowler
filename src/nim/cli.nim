import os,
       uri,
       std/enumerate,
       nimpy {.all.},
       cligen,
       strformat,
       chronos
import
    cfg,
    types,
    server_types,
    server_tasks,
    translate_types,
    cache,
    articles,
    topics,
    publish,
    stats,
    search,
    server


proc clearPage*(url: string) =
    # initThread()
    let
        relpath = url.parseUri.path
        capts = uriTuple(relpath)
    if capts.art != "":
        waitFor deleteArt(capts, cacheOnly=true)
    else:
        deletePage(relpath)

proc clearPageCache(force = false) =
    # Clear page cache database
    if force or os.getenv("DO_SERVER_CLEAR", "") == "1":
        echo fmt"Clearing pageCache at {pageCache[].path}"
        pageCache[].clear()
    else:
        echo "Ignoring doclear flag because 'DO_SERVER_CLEAR' env var is not set to '1'."

import topics, uri
proc clearSource(domain: string) =
    # initThread()
    for topic in topicsCache.keys:
        for pn in 0..(waitFor lastPageNum(topic)):
            let arts = (waitFor getDoneArticles(topic, pn))
            for ar in arts:
                if parseUri(ar.url).hostname == domain:
                    let capts = uriTuple("/" & topic & "/" & $pn & "/" & ar.slug)
                    waitFor deleteArt(capts)

proc cliPubTopic(topic: string) =
    # initThread()
    discard waitFor pubTopic(topic)

proc cliReindexSearch() =
    # initThread()
    waitFor pushAllSonic(clear = true)

# import system/nimscript
# import os
proc versionInfo() =
    let releaseType = when defined(release):
                      "release"
                  elif defined(debug):
                      "debug"
                  else:
                      "danger"

    const nimcfg = readFile(PROJECT_PATH / "nim.cfg")
    echo "build profile: ", releaseType
    echo "config: \n", nimcfg
    discard


when isMainModule:
    dispatchMulti([startServer], [clearPage], [cliPubTopic], [cliReindexSearch], [clearSource], [clearPageCache], [versionInfo])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)

# import test                     #
