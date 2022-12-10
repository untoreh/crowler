import std/[os, uri, tables, httpcore, xmltree, xmlparser, algorithm,
            parseutils, hashes, times, sets, strutils, deques, random], chronos

import cfg, types, utils, nativehttp, pyutils, locktpl, cj_lang, generator, data

{.experimental: "notnil".}
type XmlNodeNotNil = XmlNode not nil

const CJ_CACHE_PATH = DATA_PATH / "ads" / WEBSITE_NAME / "cj"
const CJ_LINKS_ENDPOINT = parseUri("https://link-search.api.cj.com/v2/link-search")

if not dirExists(CJ_CACHE_PATH):
  createDir(CJ_CACHE_PATH)


proc get_site_config(name: string): string =
  syncPyLock():
    return site.getAttr("_config").callMethod("get", name).to(string)

import std/importutils
proc children(x: XmlNode): seq[XmlNode] =
  privateAccess(XmlNode)
  return x.s

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
    recordsPerPage = "records-per-page"
  LinkTypeVal = enum
    banner = "banner"
    text = "text link"
  Query = tuple[ltv: LinkTypeVal, kws, lang, page: string]

var
  CJ_INIT = false
  CJ_ID: ptr string
  CJ_TOKEN: ptr string
  db: LockDB
  cache: LockLruCache[string, XmlNode]
  sessions: LockLruCache[Query, ref HashSet[uint]]
  queryCache: LockLruCache[Query, Deque[Query]]
  sizeCache: LockLruCache[(Query, uint), seq[XmlNode]]
  apiCallsFuts: LockLruCache[Uri, Future[XmlNode]]
  defaultQueryBanner: ptr XmlNode
  defaultQueryText: ptr XmlNode

var apiCounter = (lastMinute: default(Time), val: 0)
const apiLimit = 25
const apiInterval = initDuration(minutes = 1)
proc delay() {.async.} =
  # 25 queries per minute
  if apiCounter.val >= apiLimit:
    let diff = getTime() - apiCounter.lastMinute
    if diff < apiInterval:
      let nextMinuteInterval = (apiInterval - diff).inmilliseconds.milliseconds
      await sleepAsync(nextMinuteInterval)
    apiCounter.lastMinute = getTime()
    apiCounter.val.reset
  else:
    apiCounter.val.inc

proc getLinks(k: string): Future[XmlNode] {.async.} =
  try:
    result = cache.lcheckOrPut(k, db[k].parseXml)
  except:
    discard

proc get_epc(n: XmlNode): float =
  let epc_node = n.findEl("three-month-epc")
  if not epc_node.isnil:
    let epc_val = epc_node.innerText
    if epc_val != "N/A":
      try: discard parseFloat(epc_val, result)
      except: discard
#
proc compare_epc(a: XmlNode, b: XmlNode): int =
  let
    aepc = a.get_epc
    bepc = b.get_epc
  if aepc > bepc: 1
  elif aepc < bepc: -1
  else: 0

proc callApi(url: Uri, headers: HttpHeaders): Future[Response] {.async.} =
  await delay()
  result = (await get(url, headers = headers, proxied = false))
  if result.code != Http200:
    raise newException(ValueError, result.body)

proc doQuery(url: Uri, headers: HttpHeaders = nil): Future[XmlNode] {.async.} =
  let k = $url
  var links = await getLinks(k)
  if links.isnil:
    let resp = await callApi(url, headers)
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
      db[k] = $sortedLinks
      (cache[k], links[]) = (sortedLinks, sortedLinks[])
    else:
      links = newElement("sorted-links")
      db[k] = $links
      cache[k] = links
  return links


proc buildQuery(kws = "", lt = banner, id = "", token = "",
                num = 100'u8, page = 0'u8, lang = ""): tuple[u: Uri,
                    h: HttpHeaders] =
  ## lt: "banner" or "text link" are the most popular
  var params: seq[(string, string)]
  params.add ($websiteId, id)
  params.add ($linkType, $lt)
  if kws.len > 0:
    params.add ($keywords, kws)
  params.add ($advertiserIds, "joined")
  params.add ($recordsPerPage, $num)
  if page > 0:
    params.add ($pageNumber, $page)
  if lang.len > 0:
    params.add ($language, $lang.cjLangCode)
  var url: Uri
  let headers = newHttpHeaders()
  headers["Authorization"] = "Bearer " & token
  url.scheme = CJ_LINKS_ENDPOINT.scheme
  url.hostname = CJ_LINKS_ENDPOINT.hostname
  url.path = CJ_LINKS_ENDPOINT.path
  url.query = params.encodeQuery()
  return (url, headers)


proc ofSize(links: XmlNode, q: Query,  width = 728'u, strict: static[bool] = true,
                            vertical: static[bool] = false): seq[XmlNode] =
  sizeCache.lcheckOrPut((q, width)):
    var w, h: XmlNode
    var linkWidth, linkHeight: uint
    when vertical:
      template vertical(): bool = linkHeight > linkWidth
    else:
      template vertical(): bool = linkHeight <= linkWidth
    when strict:
      template check(): bool = linkWidth == width
    else:
      template check(): bool = linkWidth <= width

    for l in links:
      w = l.child("creative-width")
      if not w.isnil:
        let nw = parseUint(w.innerText, linkWidth)
        if nw > 0:
          h = l.child("creative-height")
          if not h.isnil:
            let nh = parseUint(h.innerText, linkHeight)
            if nh > 0 and check() and vertical():
              result.add l
              debug "cj: added link ({linkWidth}w {linkHeight}h)"
            else:
              debug "cj: skipped link ({linkWidth}w {linkHeight}h)"
    if links.tag != "sorted-links": # links where not sorted, sort them
      result.sort(compare_epc, Descending)
    result

proc initCJ*() =
  if likely(CJ_INIT):
    return
  if CJ_ID.isnil:
    CJ_ID = create(string)
    CJ_ID[] = get_site_config("cjid")
  if CJ_TOKEN.isnil:
    CJ_TOKEN = create(string)
    CJ_TOKEN[] = get_site_config("cjtoken")
  db = init(LockDB, CJ_CACHE_PATH / "cj.db", ttl = initDuration(days = 180))
  cache = initLockLruCache[string, XmlNode](32)
  sessions = initLockLruCache[Query, ref HashSet[uint]](32)
  queryCache = initLockLruCache[Query, Deque[Query]](32)
  sizeCache = initLockLruCache[(Query, uint), seq[XmlNode]](32)
  apiCallsFuts = initLockLruCache[Uri, Future[XmlNode]](10000)
  try:
    block:
      let (url, headers) = buildQuery(lt = banner, id = CJ_ID[], token = CJ_TOKEN[])
      info "Initial blocking cj api query for default banners..."
      defaultQueryBanner = create(XmlNode)
      defaultQueryBanner[] = waitFor doQuery(url, headers)
    block:
      let (url, headers) = buildQuery(lt = text, id = CJ_ID[], token = CJ_TOKEN[])
      info "Initial blocking cj api query for default texts..."
      defaultQueryText = create(XmlNode)
      defaultQueryText[] = waitFor doQuery(url, headers)
  except:
    logexc()
    quit()
  randomize()
  CJ_INIT = true

template linkTag(link: XmlNode, t: string): string =
  let c = link.child(t)
  if not c.isnil:
    c.innerText
  else:
    ""

proc adId(link: XmlNode): uint = discard linkTag(link,
    "advertiser-id").parseUint(result)
proc cjUrl*(link: XmlNode): string = linkTag(link, "clickUrl")
proc cjHtml*(link: XmlNode): string = linkTag(link, "link-code-html")
proc cjJs*(link: XmlNode): string = linkTag(link, "link-code-javascript")
proc id(link: XmlNode): uint = discard linkTag(link, "link-id").parseUint(result)

type BannerSize* = enum des, tab, pho

proc fallback(q: Query): XmlNode {.gcsafe.} =
  case q.ltv:
    of banner: defaultQueryBanner[]
    else: defaultQueryText[]

proc fetchLinks(q: Query, timeout: static[int] = 500): Future[XmlNodeNotNil] {.async.} =
  var
    url: Uri
    headers: HttpHeaders
    links: XmlNode
  (url, headers) = buildQuery(kws = q.kws, lt = q.ltv, id = CJ_ID[],
      token = CJ_TOKEN[], lang = q.lang)

  func ms(x: Natural): chronos.timer.Duration = chronos.timer.milliseconds(x)

  let fut = lcheckOrPut(apiCallsFuts, url, doQuery(url, headers))
  discard await race(fut, sleepAsync(timeout.ms))
  links =
    if fut.finished() and fut.completed(): fut.read()
    else: fallback(q)
  checkNil(links):
    result = links

template dedupLink(links, getter): string {.dirty.} =
  var res: string
  block:
    let sess =
      sessions.lgetOrPut(qid, new(HashSet[uint]))
    var n_links = links.len
    var idx = rand(min(max(0, n_links - 1), 4))
    while idx < n_links:
      let link = links[idx]
      let id = link.getter()
      if id in sess[]: # only show one ad per advertiser
        idx.inc
        continue
      else:
        sess[].incl id
        res = link.cjHtml
        # assert id in sessions[sessionId()]
        break
      idx.inc
  try: # Links should have elements all the times
    if res.len == 0:
      res = links[0].cjHtml
  except:
    discard
  res


proc queryMatrix(ltv: LinkTypeVal, kws: seq[string], topic,
    lang: string): Deque[Query] =
  queryCache.lcheckOrPut((ltv, if kws.len > 0: kws[0] else: "", topic, lang)):
    var res: Deque[Query]
    let kwsStr = join(kws, " ")
    let exactTopic = "+" & topic.replace(" ", " +")
    let kws = join([exactTopic, kwsStr], " ").alnum.tolower
    template inst(a, b, c) = res.addLast (ltv, a, b, c)
    inst kws, lang, ""
    inst exactTopic, "", ""
    inst topic, lang, ""
    inst topic, "", ""
    inst "", "", ""
    inst "", "", "2"
    inst "", "", "3"
    res

template retry(trg, code) =
  var queries = queryMatrix(ltv, kws, topic, lang)
  let qid {.inject.} = queries[0]
  when declared(doClear):
    when doClear:
      block:
        if qid in sessions:
          sessions[qid][].clear()
  while trg.len == 0 and queries.len > 0:
    let q {.inject.} = queries.popFirst()
    let links {.inject.} = await fetchLinks(q)
    code

template retry() =
  var links {.inject.}: XmlNode
  while queries.len > 0:
    let q = queries.popFirst()
    links = await fetchLinks(q)
    if links.len > 0:
      break

proc getBanner*(topic: string,
                kws: seq[string] = @[], size = des,
                lang: string = "English",
                vertical: static[bool] = false,
                doClear: static[bool] = false): Future[string] {.async.} =
  let ltv = banner
  const widths =
    when vertical: [160'u, 120, 80]
    else: [728'u, 468, 250]

  retry(result):
    let selected =
      case size:
        of des: links.ofSize(q, width = widths[0], vertical = vertical)
        of tab: links.ofSize(q, width = widths[1], vertical = vertical)
        of pho: links.ofSize(q, width = widths[2], strict = false,
            vertical = vertical)
    result = dedupLink(selected, adId)

proc getTextLink*(topic: string, kws: seq[string] = @[],
    lang: string = "English"): Future[string] {.async.} =
  let ltv = text
  retry(result):
    result = dedupLink(links, id)

proc adsLinksGen*(topic: string, kws: seq[string] = @[],
    lang: string = "English", getter: proc(
        x: XmlNode): string = cjHtml): Future[Generator[XmlNode,
        string]] {.async.} =
  var queries = queryMatrix(text, kws, topic, lang)
  retry()
  let sess = sessions.lgetOrPut(queries[0], new(HashSet[uint]))
  sess[].clear()
  proc mut(link: XmlNode): string {.gcsafe.} =
    if link.id notin sess[]:
      result = link.cjHtml
  result = newGen[XmlNode, string](links.children, mut)

when isMainModule:
  initHttp()
  initCJ()
  # let id = waitFor get_site_config("cjid")
  # let id = waitFor get_site_config(cjtoken)
  # proc run() {.async.} =
    # let id = "."
    # let token = "1gra97nerye25a7dfdy07erj6q"
    # let (url, headers) = buildQuery(kws = "vps", lt = text, id = id, token = token)
    # let links = await doQuery(url, headers)
    # echo links[0].linkHtml
    # echo links.ofSize(width = 728)
    # echo links.ofSize(width = 468, strict = false)
    # echo links.ofSize(width = 250, strict = false, vertical = false)

  db.clear()
  echo waitFor getBanner("web")
  echo waitFor getBanner("web")
  echo waitFor getBanner("web")
