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
    stats


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


proc cliPubTopic(topic: string) =
    initThread()
    pubTopic(topic)

when isMainModule:
    dispatchMulti([start], [clearPage], [cliPubTopic])
    # initCache()
    # let url = "http://wsl:5050/web/0/6-best-shared-web-hosting-services-companies-2022"
    # clearPage(url)
