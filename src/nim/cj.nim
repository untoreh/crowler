import std/[os, uri, tables, httpcore, xmltree, xmlparser, algorithm,
    parseutils, hashes, times], chronos

import cfg, utils, nativehttp #, pyutils

const CJ_CACHE_PATH = DATA_PATH / "ads" / "cj"
const CJ_LINKS_ENDPOINT = parseUri("https://link-search.api.cj.com/v2/link-search")

if not dirExists(CJ_CACHE_PATH):
  createDir(CJ_CACHE_PATH)

type
  Param = enum
    websiteId = "website-id"
    linkType = "link-type"
    advertiserIds = "advertiser-ids"
    keywords = "keywords"
    category = "category"
    language = "language"
    promotionType = "promotion-type"
    pageNumber = "page-number"

proc queryCachedPath(k: string): string = CJ_CACHE_PATH / ($hash(k) & ".zst")
proc getCachedPath(cachedPath: string): Future[string] {.async.} =
  let data = await readFileAsync(cachedPath)
  return decompress[string](data)
proc storeCachedPath(data: string, cachedPath: string) {.async.} =
  await writeFileAsync(cachedPath, compress(data))

proc isExpired(path: string): bool =
  if not fileExists(path):
    true
  else:
    let expiryLimit = getTime() - seconds(60 * 60 * 24 * 7)
    getCreationTime(path) > expiryLimit

proc getLinks(cachedPath: string): Future[XmlNode] {.async.} =
  if not cachedPath.isExpired:
    result = (await getCachedPath(cachedPath)).parseXml

# proc get_site_config(name: string): Future[string] {.async.} =
#   withPyLock():
#     return site[].getAttr("_config").callMethod("get", "cjid").to(string)
#
#
proc get_epc(n: XmlNode): float =
  let epc_node = n.findEl("three-month-epc")
  if not epc_node.isnil:
    let epc_val = epc_node.innerText
    if epc_val != "N/A":
      try: discard parseFloat(epc_val, result)
      except: discard
#
proc compare_epc(a: XmlNode, b: XmlNode): int = int(a.get_epc > b.get_epc)

proc doQuery(url: Uri, headers: HttpHeaders = nil) {.async.} =
  let k = ($url).queryCachedPath
  var links = await getLinks(k)
  if links.isnil:
    let resp = (await get(url, headers = headers, proxied = false))
    let x = resp.body.parseXml
    if x.tag == "cj-api":
      let allLinks = x.child("links")
      if not allLinks.isnil:
        new(links)
        links[] = allLinks[]
    if not links.isnil and len(links) > 0:
      var nodes = links.findall("link")
      nodes.sort(compare_epc, Descending)
      let sortedLinks = newElement("sorted-links")
      for n in nodes:
        sortedLinks.add n
      await storeCachedPath($sortedLinks, k)
      links = sortedLinks

proc buildQuery(kws="", linkTypeVal="banner", id = "", token = ""): (u: Uri, h: HttpHeaders) =
  var params: seq[(string, string)]
  params.add ($websiteId, id)
  params.add ($linkType, linkTypeVal)
  params.add ($keywords, kws)
  params.add ($advertiserIds, "joined")
  var url: Uri
  let headers = newHttpHeaders()
  headers["Authorization"] = "Bearer " & token
  url.scheme = CJ_LINKS_ENDPOINT.scheme
  url.hostname = CJ_LINKS_ENDPOINT.hostname
  url.path = CJ_LINKS_ENDPOINT.path
  url.query = params.encodeQuery()
  return (url, headers)

when isMainModule:
  initHttp()
  # let id = waitFor get_site_config("cjid")
  # let id = waitFor get_site_config(cjtoken)
  let id = "."
  let token = "1gra97nerye25a7dfdy07erj6q"
  let (url, headers) = buildQuery()

  waitFor doQuery(url, headers)
