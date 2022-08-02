import karax/[vdom, karaxdsl], strformat, locks, sugar, strutils, uri, parsexml,
    streams, std/algorithm
import chronos, chronos/asyncsync, htmlparser, xmltree
import os
import sets
import cfg
import utils
import cache
import html_entities
import html_misc

# NOTE: the space ' ' inside the `<script> </script>` tag is IMPORTANT to prevent `</>` tag collapsing, since it breaks html
const
  ADSENSE_SRC* = """<script async src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-7303639355435813" crossorigin="anonymous"> </script>"""
  ADSENSE_AMP_HEAD* = """<script async custom-element="amp-auto-ads" src="https://cdn.ampproject.org/v0/amp-auto-ads-0.1.js"> </script>"""
  ADSENSE_AMP_BODY* = """<amp-auto-ads type="adsense" data-ad-client="ca-pub-7303639355435813"> </amp-auto-ads>"""

let
  ADS_HEAD* = create(XmlNode)
  ADS_HEADER* = create(XmlNode)
  ADS_SIDEBAR* = create(XmlNode)
  ADS_FOOTER* = create(XmlNode)
  ADS_FOOTERLINKS* = create(seq[string])
  ADS_LINKS* = create(seq[string])
  ADS_ARTICLES* = create(XmlNode)
  ADS_RELATED* = create(XmlNode)
  ADS_SEPARATOR* = create(XmlNode)

var locksInitialized: bool
var adsFirstRead*, assetsFirstRead*: bool
var adsHeadLock, adsHeaderLock, adsSidebarLock, adsFooterLock,
  adsFooterLinksLock, adsLinksLock, adsArticlesLock, adsRelatedLock,
    adsSeparatorLock: ptr AsyncLock

var adsLinksCount, adsLinksIdx, adsFooterLinksCount, adsFooterLinksIdx: int

template withSyncLock(l: AsyncLock, code) =
  try:
    waitFor l.acquire()
    code
  finally:
    l.release()

template withASyncLock(l: AsyncLock, code) =
  try:
    await l.acquire()
    code
  finally:
    l.release()

import macros
macro initLocks(syms: varargs[untyped]) =
  result = newNimNode(nnkStmtList)
  for sym in syms:
    result.add quote do:
      `sym` = create(AsyncLock)
      `sym`[] = newAsyncLock()
  result.add quote do:
    locksInitialized = true

template initLinks(name, data) =
  if fileExists(`name File`):
    let links = readFile(`name File`)
    data[] = links.split()
    `name Idx` = 0
    `name Count` = data[].len
    if `name Count` == 0:
      data[].setLen(1)
      `name Count` = 1

proc readAdsConfig*() =
  if unlikely(not locksInitialized):
    initLocks adsHeadLock, adsHeaderLock, adsSidebarLock, adsFooterLock,
        adsFooterLinksLock, adsLinksLock, adsArticlesLock, adsRelatedLock, adsSeparatorLock

  withSyncLock(adsHeadLock[]):
    let adsHeadFile = DATA_ADS_PATH / "head.html"
    if fileExists(adsHeadFile):
      ADS_HEAD[] = loadHtml(adsHeadFile)
  withSyncLock(adsHeaderLock[]):
    let adsHeaderFile = DATA_ADS_PATH / "header.html"
    if fileExists(adsHeaderFile):
      ADS_HEADER[] = loadHtml(adsHeaderFile)
  withSyncLock(adsSidebarLock[]):
    let adsSidebarFile = DATA_ADS_PATH / "sidebar.html"
    if fileExists(adsSidebarFile):
      ADS_SIDEBAR[] = loadHtml(adsSidebarFile)
  withSyncLock(adsFooterLock[]):
    let adsFooterFile = DATA_ADS_PATH / "footer.html"
    if fileExists(adsFooterFile):
      ADS_FOOTER[] = loadHtml(adsFooterFile)
  # Footer links
  withSyncLock(adsFooterLinksLock[]):
    let adsFooterLinksFile = DATA_ADS_PATH / "footerlinks.txt"
    initLinks adsFooterLinks, ADS_FOOTERLINKS
  # Links
  withSyncLock(adsLinksLock[]):
    let adsLinksFile = DATA_ADS_PATH / "links.txt"
    initLinks adsLinks, ADS_LINKS
  withSyncLock(adsArticlesLock[]):
    let adsArticlesFile = DATA_ADS_PATH / "articles.html"
    if fileExists(adsArticlesFile):
      ADS_ARTICLES[] = loadHtml(adsArticlesFile)
  withSyncLock(adsRelatedLock[]):
    let adsRelatedFile = DATA_ADS_PATH / "related.html"
    if fileExists(adsRelatedFile):
      ADS_RELATED[] = loadHtml(adsRelatedFile)
  withSyncLock(adsSeparatorLock[]):
    let adsSeparatorFile = DATA_ADS_PATH / "separator.html"
    if fileExists(adsSeparatorFile):
      ADS_SEPARATOR[] = loadHtml(adsSeparatorFile)

template nextLink(name, data) =
  withASyncLock(`name Lock`[]):
    if unlikely(`name Idx` == 0):
      result = data[][0]
      `name Idx` += 1
    else:
      result = data[][`name Count`.mod(`name Idx`)]
      `name Idx` = if `name Idx` >= `name Count`: 0 else: `name Idx` + 1

proc nextAdsLink*(): Future[string] {.async.} =
  nextLink adsLinks, ADS_LINKS

proc nextFooterLink*(): Future[string] {.async.} =
  nextLink adsFooterLinks, ADS_FOOTERLINKS

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
    of footer: await nextFooterLink()
  return buildHtml(a(href = link, class = "ad-link")):
    adLinkIco true, stl
    text "Ad"
    adLinkIco false, stl

template adLink*(kind; stl: static): auto =
  await adLinkFut(kind, stl)

template adLink*(kind): auto =
  await adLinkFut(kind, static(AdLinkStyle.wrap))


proc insertAd*(name: ptr XmlNode): seq[VNode] {.gcsafe.} =
  result = newSeq[VNode]()
  when declared(name):
    if not name[].isnil:
      for el in name[].filter():
        result.add verbatim(el.withClosingHtmlTag)
    else:
      warn("{name} is nil.")
  else:
    warn("{name} not defined, ignoring ads.")

proc replaceLinks*(str: string, chunksize = 250): Future[string] {.async.} =
  ## chunksize is the number of chars between links

  var maxsize = str.len
  var chunkpos = if chunksize >= maxsize: maxsize.div(2)
                else: chunksize
  var positions: seq[int]
  while chunkpos <= maxsize:
    positions.add(chunkpos)
    chunkpos += chunksize
  positions.reverse()

  var s = newStringStream(str)
  if s == nil:
    raise newException(CatchableError, "ads: cannot convert str into stream")
  var x: XmlParser
  var txtpos, prevstrpos, strpos: int
  var filled: bool
  open(x, s, "")
  defer: close(x)
  next(x)
  while true:
    case x.kind:
      of xmlCharData:
        let
          txt = x.charData
          txtStop = txt.len
        prevstrpos = strpos
        strpos = x.offsetBase + x.bufpos + 2 - txtStop
        # add processed non text data starting from previous point
        result.add str[prevstrpos..<strpos]
        if unlikely(positions.len == 0):
          result.add txt
          continue
        for (w, isSep) in txt.tokenize():
          txtpos += w.len
          if txtpos > positions[^1]:
            if (not isSep) and (w.len > 5):
              let link = buildhtml(a(href = (await nextAdsLink()),
                  class = "ad-link")): text w
              result.add $link
              discard positions.pop()
            else:
              result.add w
            if positions.len == 0:
              result.add txt[txtpos..^1]
              break
          else:
            result.add w
      of xmlEof:
        break
      else:
        if filled:
          break
    next(x)


import std/os
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
proc loadAssets() =
  assetsFiles[].clear()
  for (kind, file) in walkDir(DATA_ASSETS_PATH):
    assetsFiles[].incl file.extractFilename()

proc updateAssets(event: seq[PathEvent]) {.gcsafe.} =
  withLock(assetsFileLock):
    let prevnum = assetsFiles[].len
    for filename in assetsFiles[]:
      {.cast(gcsafe).}:
        pageCache[].del(filename)
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
  if not dirExists(DATA_ASSETS_PATH):
    createDir(DATA_ASSETS_PATH)
  loadAssets()
  assetsFirstRead = true
  var thr {.global.}: Thread[(string, WatchKind)]
  createThread(thr, pollWatcher, (DATA_ASSETS_PATH, WatchKind.assets))
