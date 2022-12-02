import std/[os, times, uri, enumerate, strformat, strutils]
import nimpy {.all.}, cligen, chronos, karax/vdom
when compileOption("profiler"):
  import nimprof
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
  server,
  html,
  ads

# import ./test                     #
# static: echo "using test!"

template initAll() =
  initThread()
  initCache()
  initStats()

proc clearPage*(url: string) =
  initAll()
  let
    relpath = url.parseUri.path
    capts = uriTuple(relpath)
  if capts.art != "":
    waitFor deleteArt(capts, cacheOnly = true)
  else:
    deletePage(relpath)

proc clearPageCache(force = false) =
  # Clear page cache database
  if force or os.getenv("DO_SERVER_CLEAR", "") == "1":
    echo fmt"Clearing pageCache at {pageCache.path}"
    pageCache.clear()
  else:
    echo "Ignoring doclear flag because 'DO_SERVER_CLEAR' env var is not set to '1'."

import topics, uri
proc clearSource(domain: string) =
  initAll()
  for topic in topicsCache.keys:
    for pn in 0..(waitFor lastPageNum(topic)):
      let arts = (waitFor getDoneArticles(topic, pn, rev=false))
      for ar in arts:
        if parseUri(ar.url).hostname == domain:
          let capts = uriTuple("/" & topic & "/" & $pn & "/" & ar.slug)
          waitFor deleteArt(capts)

proc removeArt(url: string) =
  ## Delete article from database
  initAll()
  let uri = parseUri(url)
  let capts = uriTuple(uri.path)
  waitFor deleteArt(capts, cacheOnly = false)

proc cliPubTopic(topic: string) =
  initAll()
  discard waitFor pubTopic(topic)

proc cliReindexSearch() =
  initAll()
  waitFor pushAllSonic()

proc cliShowStats(topic: string, count: int) =
  initAll()
  waitFor showStats(topic, count)

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

proc genPage(relpath: string) =
  readAdsConfig()
  let
    relpath = relpath.parseUri.path
    capts = uriTuple(relpath)
  let page = if capts.topic == "":
               let pagetree = (waitFor buildHomePage(capts.lang, capts.amp))[1]
               cast[string]($pagetree)
             elif capts.topic in customPages:
               (waitFor pageFromTemplate(capts.topic, capts.lang, capts.amp))
             else:
               let topic = capts.topic
               let pagenum = capts.page
               let arts = waitFor getDoneArticles(topic,
                   pagenum = pagenum.parseInt)
               let content = waitfor buildShortPosts(arts)
               # if the page is not finalized, it is the homepage
               let footer = waitFor pageFooter(topic, pagenum, home = false)
               let pagetree = waitFor buildPage(title = "", # this is NOT a `title` tag
               content = verbatim(content),
               slug = pagenum,
               pagefooter = footer,
               topic = topic)
               pagetree.asHtml
  writeFile(SITE_PATH / "index.html", page)


proc cliCompactData(name = "translate.db") =
  let path = WEBSITE_PATH / name
  if not fileExists(path):
    raise newException(OSError, "Database does not appear to exist")
  let db = init(LockDB, path, ttl = initDuration())
  db.compact()

when isMainModule:
  dispatchMulti([startServer], [clearPage], [cliPubTopic], [cliReindexSearch], [
      clearSource], [clearPageCache], [versionInfo], [cliShowStats], [removeArt], [cliCompactData])

  # initThread()
  # genPage("/")

# import http
