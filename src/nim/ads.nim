import karax/[vdom, karaxdsl], strformat, locks, sugar
import asyncdispatch, htmlparser, xmltree
import os
import cfg
import utils
import cache

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

var adsConfigLock: Lock
initLock(adsConfigLock)

proc readHtml(path: string): XmlNode =
    readFile(path).parseHtml

proc readAdsConfig*() =
    withLock(adsConfigLock):
        let adsHeadFile = DATA_ADS_PATH / "head.html"
        if fileExists(adsHeadFile):
            ADS_HEAD[] = loadHtml(adsHeadFile)
        let adsHeaderFile = DATA_ADS_PATH / "header.html"
        if fileExists(adsHeaderFile):
            ADS_HEADER[] = loadHtml(adsHeaderFile)
        let adsSidebarFile = DATA_ADS_PATH / "sidebar.html"
        if fileExists(adsSidebarFile):
            ADS_SIDEBAR[] = loadHtml(adsSidebarFile)
        let adsFooterFile = DATA_ADS_PATH / "footer.html"
        if fileExists(adsFooterFile):
            ADS_FOOTER[] = loadHtml(adsFooterFile)

import strutils
import sets
const selfClosingTags = ["area", "base", "br", "col", "embed", "r", "img", "input", "link", "meta",
        "param", "source", "track", "wbr", ].toHashSet
proc withClosingHtmlTag(el: XmlNode): string =
    ## `htmlparser` package seems to avoid closing tags for elements with no content
    result = $el
    if result.endsWith("/>") and not (el.tag in selfClosingTags):
        result[^2] = ' '
        result.add "</" & el.tag & ">"

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

import std/os
import fsnotify

proc updateAds(event: seq[PathEvent]) =
    for e in event:
        if e.action == Modify:
            readAdsConfig()
            info "ads: config updated"
        break

proc runAdsWatcher*() =
    var watcher = initWatcher()
    register(watcher, DATA_ADS_PATH, updateAds)
    while true:
        poll(watcher, 1000)

var assetsFileLock: Lock
initLock(assetsFileLock)
let assetsFiles* = create(HashSet[string])
proc updateAssets(event: seq[PathEvent]) {.gcsafe.} =
    withLock(assetsFileLock):
        let prevnum = assetsFiles[].len
        for filename in assetsFiles[]:
            {.cast(gcsafe).}:
                pageCache[].del(filename)
        for e in event:
            if e.action in [Create, Modify, Rename, Remove].toHashSet:
                assetsFiles[].clear()
                for (kind, file) in walkDir(DATA_ASSETS_PATH):
                    assetsFiles[].incl file.extractFilename()
            break
        info "assets: files list updated {prevnum} -> {assetsFiles[].len}"

proc runAssetsWatcher*() =
    var watcher = initWatcher()
    if not dirExists(DATA_ASSETS_PATH):
        createDir(DATA_ASSETS_PATH)
    register(watcher, DATA_ASSETS_PATH, updateAssets)
    while true:
        poll(watcher, 1000)
