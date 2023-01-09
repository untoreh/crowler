import translate
when isMainModule:
    let topic = "vps"
    # refreshPageSizes(topic)
    dopublish(topic)
    quitl()
    let
        topdir = 0
        nPagePosts = pageSize(topic, topdir)
    # pubPage(topic, $topdir, nPagePosts, finalize = false, with_arts = true)
    # pubPageFromTemplate("dmca.html", "DMCA")
