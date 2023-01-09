import "../src/nim/server"

when isMainModule:
  # initThread()
  # let topic = "vps"
  # let page = buildHomePage("en", "")
  # page.writeHtml(SITE_PATH / "index.html")
  # initSonic()
  # let argt = getLastArticles(topic)
  # echo buildRelated(argt[0])
  # imgCache.clear()
  startServer(doclear = true)
