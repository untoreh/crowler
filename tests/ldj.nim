when isMainModule:
    let
        url = $config.websiteUrl
        auth = "fra"
        year = 2022
        pls = {"asd": 1, "pls": 2}
    echo video("ok", "url", views="nice")
    echo place()
    echo "ok"
    for k, v in pls.items:
        echo k, " v: ", v
    echo website(url, author, year)
