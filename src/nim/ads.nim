import std/[os, sets, htmlparser, xmltree, parsexml, strformat, strutils, locks,
    sugar, streams, algorithm, macros]
import karax/[vdom, karaxdsl]
import chronos, chronos/asyncsync

import types, cfg, utils, cache, html_entities, html_misc, cj

export cj

# NOTE: the space ' ' inside the `<script> </script>` tag is IMPORTANT to prevent `</>` tag collapsing, since it breaks html

proc getVNode(): ptr VNode =
  result = create(VNode)
  result[] = newVNode(VNodeKind.verbatim)

let
  adsHead* = getVNode()
  adsHeader* = getVNode()
  adsSidebar* = getVNode()
  adsFooter* = getVNode()
  adsLinks* = create(seq[string])
  adsArticles* = getVNode()
  adsRelated* = getVNode()
  adsSeparator* = getVNode()

var locksInitialized: bool
var adsFirstRead*, assetsFirstRead*: bool
var adsHeadLock*, adsHeaderLock*, adsSidebarLock*, adsFooterLock*,
  adsLinksLock*, adsArticlesLock*, adsRelatedLock*,
    adsSeparatorLock*: Lock

var adsLinksCount, adsLinksIdx: int

macro loadIfExists(basename: static[string], varname) =
  let path = DATA_ADS_PATH / basename
  quote do:
    when fileExists(`path`):
      const `varname`* = readFile(`path`)

when defined(adsense):
  loadIfExists("adsense.html", ADSENSE_SRC)
  loadIfExists("amphead.html", ADSENSE_AMP_HEAD)
  loadIfExists("ampbody.html", ADSENSE_AMP_BODY)

template initLinks(name, data) =
  if fileExists(`name File`):
    let links = readFile(`name File`)
    data[] = collect:
      for link in links.splitLines():
        if link.len > 0 and (sre(r"^\s*#") notin link):
          link.withScheme
    `name Idx` = 0
    `name Count` = data[].len
    if `name Count` == 0:
      data[].setLen(1)
      `name Count` = 1

proc adsVNode(el: XmlNode): VNode {.gcsafe.} =
  result = newVNode(VNodeKind.verbatim)
  if not el.isnil and el.kind == xnElement:
    for e in el:
      result.add e.withClosingHtmlTag.verbatim

proc readAdsConfig*() =
  withLock(adsHeadLock):
    let adsHeadFile = DATA_ADS_PATH / "head.html"
    if fileExists(adsHeadFile):
      takeOverFields(loadHtml(adsHeadFile).adsVNode, adsHead[])
  withLock(adsHeaderLock):
    let adsHeaderFile = DATA_ADS_PATH / "header.html"
    if fileExists(adsHeaderFile):
      takeOverFields(loadHtml(adsHeaderFile).adsVNode, adsHeader[])
  withLock(adsSidebarLock):
    let adsSidebarFile = DATA_ADS_PATH / "sidebar.html"
    if fileExists(adsSidebarFile):
      takeOverFields(loadHtml(adsSidebarFile).adsVNode, adsSidebar[])
  withLock(adsFooterLock):
    let adsFooterFile = DATA_ADS_PATH / "footer.html"
    if fileExists(adsFooterFile):
      takeOverFields(loadHtml(adsFooterFile).adsVNode, adsFooter[])
  # Links
  withLock(adsLinksLock):
    let adsLinksFile = DATA_ADS_PATH / "links.txt"
    initLinks adsLinks, adsLinks
  withLock(adsArticlesLock):
    let adsArticlesFile = DATA_ADS_PATH / "articles.html"
    if fileExists(adsArticlesFile):
      takeOverFields(loadHtml(adsArticlesFile).adsVNode, adsArticles[])
  withLock(adsRelatedLock):
    let adsRelatedFile = DATA_ADS_PATH / "related.html"
    if fileExists(adsRelatedFile):
      takeOverFields(loadHtml(adsRelatedFile).adsVNode, adsRelated[])
  withLock(adsSeparatorLock):
    let adsSeparatorFile = DATA_ADS_PATH / "separator.html"
    if fileExists(adsSeparatorFile):
      takeOverFields(loadHtml(adsSeparatorFile).adsVNode, adsSeparator[])

template nextLink(name, data) =
  checkNil(data):
    # checkNil `name Lock`
    withLock(`name Lock`):
      if unlikely(`name Idx` == 0):
        result = data[][0]
        `name Idx` += 1
      else:
        result = data[][`name Count`.mod(`name Idx`)]
        `name Idx` = if `name Idx` >= `name Count`: 0 else: `name Idx` + 1

proc nextAdsLink*(): Future[string] {.async.} =
  nextLink adsLinks, adsLinks

type AdLinkType* = enum tags, footer
type AdLinkStyle* = enum wrap, ico
macro adLinkIco(first: static[bool], stl: static[AdLinkStyle]): untyped =
  case stl:
    of wrap:
      if first:
        quote do:
          buildHtml(tdiv(class = "icon i-mdi-chevron-left"))
      else:
        quote do:
          buildHtml(tdiv(class = "icon i-mdi-chevron-right"))
    of ico:
      if first:
        quote do:
          buildHtml(tdiv(class = "icon i-mdi-cursor-default-click-outline"))
      else:
        quote do:
          newVNode(VNodeKind.verbatim)

proc adLinkFut(kind: AdLinkType, stl: static[AdLinkStyle]): Future[
    VNode] {.async.} =
  let link = case kind:
    of tags: await nextAdsLink()
    else: await nextAdsLink()
  result =
    if link.len > 0:
      buildHtml(a(href = link, class = "ad-link")):
        adLinkIco true, stl
        text "Ad"
        adLinkIco false, stl
    else:
      newVNode(VNodeKind.text)

template adLink*(kind; stl: static): auto =
  await adLinkFut(kind, stl)

template adLink*(kind): auto =
  await adLinkFut(kind, static(AdLinkStyle.wrap))

template withOutLock(l: Lock, code) =
  try:
    l.release()
    code
  finally:
    l.acquire()

iterator adsFromImpl(loc: ptr VNode, l: var Lock): VNode =
  if loc.isnil or loc[].isnil:
    discard
  else:
    withLock(l):
      for el in loc[]:
        withOutLock(l):
          yield el

template adsFrom*(name): VNode = adsFromImpl(name, `name Lock`)

import generator
export generator
import std/importutils
proc adsGen*(loc: ptr VNode): Iterator[VNode] =
  if loc.isnil or loc[].isnil:
    discard
  else:
    privateAccess(VNode)
    result = newIter[VNode](loc[].kids)

proc allSizeBanners*(topic: string, kws: seq[string] = @[],
    lang: string = "English", vertical: static[bool] = false, class = "",
        fallback: static[bool] = false, doClear: static[bool] = false): Future[
    VNode] {.async.} =
  var textLinks: Generator[XmlNode, string]
  when fallback:
    textLinks = await adsLinksGen(topic, kws, lang)
  result = buildHtml(tdiv(class = fmt"ads-{class}"))
  template banner(clr): string =
    await getBanner(topic, kws, sz, lang, vertical, doClear = clr)
  for sz in [des, tab, pho]:
    let ad = buildHtml(tdiv(class = $sz))
    var b = banner(doClear)
    if b.len == 0:
      b.add banner(true)
    ad.add b.verbatim
    when fallback:
      if ad[0].len == 0:
        ad[0].add textLinks.next().verbatim
    result.add ad

proc insertAds*(txt: string, charsInterval = 2500, topic = "", lang = "",
    kws: seq[string] = @[]): Future[string] {.async.} =
  ## Insert ads over `txt` after chunks of texts of specified `charsInterval` size.
  # var linksGen = await adsLinksGen(topic, kws, lang, getter = cjHtml)
  var lines = txt.splitLines()
  var idx = 0
  var chars = 0
  while idx < lines.len:
    chars += lines[idx].len
    if chars > charsInterval:
      let ad = await allSizeBanners(topic, kws, lang, class = "in-article",
          fallback = true) # This is the first call, clear session
      lines.insert($ad, idx)
      chars = 0
      idx.inc
    idx.inc
  return lines.join("\n")

# proc insertAds*(str: string, chunksize = 2500, lang = "", topic = "",
#                   kws: seq[string] = @[], staticLinks: static[
#                       bool] = false): Future[string] {.async.} =
#   ## chunksize is the number of chars between ads

#   var linksGen =
#     when staticLinks: adsGen(adsLinks)
#     else: await adsLinksGen(topic, kws, lang, getter = url)
#   if linksGen.len == 0:
#     return str

#   var maxsize = str.len
#   var chunkpos = if chunksize >= maxsize: maxsize.div(2)
#                 else: chunksize
#   var positions: seq[int]
#   while chunkpos <= maxsize:
#     positions.add(chunkpos)
#     chunkpos += chunksize
#   positions.reverse()

#   var s = newStringStream(str)
#   if s == nil:
#     raise newException(CatchableError, "ads: cannot convert str into stream")
#   var x: XmlParser
#   var txtpos, prevstrpos, strpos: int
#   var filled: bool
#   open(x, s, "")
#   defer: close(x)
#   while true:
#     next(x)
#     case x.kind:
#       of xmlCharData:
#         let
#           txt = x.charData
#           txtStop = txt.len
#         prevstrpos = strpos
#         strpos = x.offsetBase + x.bufpos - txtStop
#         # add processed non text data starting from previous point
#         if strpos > prevstrpos:
#           let tail = str[prevstrpos..strpos - 1]
#           # FIXME: The xmlparser never appears to output `xmlEntity` events
#           # and deals with entities in a strange way
#           if (tail & ";").isEntity:
#             doassert txt[0] != str[strpos + 1]
#             result.add tail
#             result.add ';' # the xmlparser skips the semicolon
#             strpos += 1
#             continue
#           else:
#             result.add tail
#             if str[strpos] == '>': # FIXME: this shouldn't be required...
#               result.add '>'
#               strpos += 1
#         strpos += txtStop # add the current text to the current string position

#         if unlikely(positions.len == 0):
#           result.add txt
#           continue
#         for (w, isSep) in txt.tokenize():
#           txtpos += w.len
#           if txtpos > positions[^1]:
#             if (not isSep) and (w.len > 5):
#               let link = buildhtml(a(href = linksGen.next,
#                   class = "ad-link")): text w
#               result.add $link
#               discard positions.pop()
#             else:
#               result.add w
#             if positions.len == 0:
#               if txtpos <= txt.len:
#                 result.add txt[txtpos..^1]
#               break
#           else:
#             result.add w
#       of xmlEof:
#         break
#       else:
#         if filled:
#           break

import fsnotify
type WatchKind = enum
  ads, assets


proc updateAds(event: seq[PathEvent]) =
  for e in event:
    if e.action == Modify:
      readAdsConfig()
      info "ads: config updated"
    break

var assetsFileLock: Lock
initLock(assetsFileLock)
let assetsFiles* = create(HashSet[string])
proc loadAssets*() =
  if not dirExists(DATA_ASSETS_PATH):
    createDir(DATA_ASSETS_PATH)
  assetsFiles[].clear()
  for (kind, file) in walkDir(DATA_ASSETS_PATH):
    assetsFiles[].incl file.extractFilename()

proc updateAssets(event: seq[PathEvent]) {.gcsafe.} =
  withLock(assetsFileLock):
    let prevnum = assetsFiles[].len
    for filename in assetsFiles[]:
      pageCache.delete(filename)
    for e in event:
      if e.action in [Create, Modify, Rename, Remove].toHashSet:
        loadAssets()
        break
    info "assets: files list updated {prevnum} -> {assetsFiles[].len}"

proc pollWatcher(args: (string, WatchKind)) {.nimcall, gcsafe.} =
  var watcher = initWatcher()
  let fn = case args[1]:
    of ads: updateAds
    of assets: updateAssets
  register(watcher, args[0], fn)
  while true:
    poll(watcher, 1000)

proc runAdsWatcher*() =
  readAdsConfig()
  adsFirstRead = true
  var thr {.global.}: Thread[(string, WatchKind)]
  createThread(thr, pollWatcher, (DATA_ADS_PATH, WatchKind.ads))

proc runAssetsWatcher*() =
  loadAssets()
  assetsFirstRead = true
  var thr {.global.}: Thread[(string, WatchKind)]
  createThread(thr, pollWatcher, (DATA_ASSETS_PATH, WatchKind.assets))

when isMainModule:
  import std/strtabs {.all.}
  import std/importutils
  runAdsWatcher()
  # for n in adsHeader[]:
  #
  #   echo n
