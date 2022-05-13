import os,
       uri,
       std/enumerate
import
    cfg,
    types,
    utils,
    server_types,
    translate_types,
    cache,
    articles,
    topics

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
    # let pyslug = capts.art.nimValueToPy()
    # for (n, a) in enumerate(pageArts):
    #     if a["slug"] == pyslug:
    #         pageArts.del(n)
    #         break

when isMainModule:
    let url = "http://wsl:5050/vps/0/"
