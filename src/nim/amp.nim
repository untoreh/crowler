import tables,
       karax / [karaxdsl, vdom, vstyles],
       sequtils,
       strutils,
       strformat,
       os,
       std/with,
       hashes,
       htmlparser,
       xmltree,
       nre,
       uri,
       lrucache,
       chronos,
       chronos/apps/http/httpclient,
       chronos/asyncsync

import cfg,
       utils,
       html_misc,
       ads

const skipNodes = [VNodeKind.iframe, audio, canvas, embed, video, img, button, form, VNodeKind.head, svg]
const skipNodesXml = ["iframe", "audio", "canvas", "embed", "video", "img", "button", "form",
        "head", "svg", "document"]

threadVars(
    (vbtmcache, LruCache[array[5, byte], XmlNode]),
    (rootDir, string),
    (ampDoc, ampHead, ampBody, styleEl1, styleEl2, styleEl2Wrapper, ampjs, charset, viewport,
            styleElCustom, VNode)
)

threadVars(
    (styleStr, string),
    (filesCache, Table[string, string]),
    (styleScript, seq[string]),
    (ampLinkEl, VNode)
)

var ampLock: ptr AsyncLock
const skipFiles = ["bundle.css"]

proc asLocalUrl(path: string): string {.inline.} =
    $(WEBSITE_URL / path.replace(SITE_PATH, ""))

var fileUri {.threadvar.}: Uri
var url {.threadvar.}: string
proc getFile(path: string): Future[string] {.async.} =
    ## This does not actually read or save contents to storage, just holds an in memory cache
    ## and fetches from remove urls
    debug "amp: getting style file from path {path}"
    try:
        result = filesCache[path]
    except KeyError:
        let filePath = DATA_PATH / "cache" / $hash(path) & splitFile(path).ext
        parseUri(path, fileUri)
        if fileUri.scheme.isEmptyOrWhitespace:
            url = path.asLocalUrl
        else:
            shallowCopy url, path
        debug "getfile: getting file content from {url}"
        filesCache[path] = (await fetch(HttpSessionRef.new(), parseUri(url))).data.bytesToString
        result = filesCache[path]


proc ampTemplate(): (VNode, VNode, VNode) =
    ##
    let tree = ampDoc.find(html)
    for node in [tree, ampHead, ampBody]:
        node.clear()

    tree.setAttr("amp", "")
    with tree:
        add ampHead
        add ampBody

    with ampHead:
        add ampjs
        add charset
        add viewport
        # amp styles
        # amp-custom goes before boilerplate
        add styleElCustom
        add styleEl1
        add styleEl2Wrapper
    ## ads
    when declared(ADSENSE_AMP_HEAD):
        ampHead.add verbatim(ADSENSE_AMP_HEAD)
        ampBody.add verbatim(ADSENSE_AMP_BODY)
    (tree, ampHead, ampBody)

proc fetchStyle(el: VNode) {.async.} =
    let src = cast[string](el.getAttr("href"))
    if src.startsWith("/"):
        let path = rootDir / src.strip(leading = true, chars = {'/'})
        styleScript.add await getFile(path)
    else:
        styleScript.add await getFile(src)

proc processHead(inHead: VNode, outHead: VNode) {.async.} =
    var
        canonicalUnset = true
    debug "iterating over {inHead.kind}"
    for el in inHead.preorder:
        case el.kind:
            of VNodeKind.text, skipNodes:
                continue
            of VNodeKind.link:
                if canonicalUnset and el.isLink(canonical):
                    outHead.add el
                    canonicalUnset = false
                elif el.isLink(stylesheet) and (not ("flags-sprite" in el.getattr("href"))):
                    await el.fetchStyle()
                else:
                    outHead.add el
            of VNodeKind.script:
                if el.getAttr("type") == $ldjson:
                    outHead.add el
            of VNodeKind.meta:
                if (el.getAttr("name") == "viewport") or (el.getAttr("charset") != ""):
                    continue
                else:
                    outHead.add el
            of VNodeKind.verbatim:
                if ($el).startsWith("<script"):
                    continue
                else:
                    outHead.add el
            else:
                debug "amphead: adding element {el.kind} to outHead."
                outHead.add el

proc parseNode(node: VNode): XmlNode =
    let
        s = node.text
        tree = try:
                   vbtmcache[s.key]
               except:
                   vbtmcache[s.key] = parseHtml(s)
                   vbtmcache[s.key]
    return deepcopy(tree)

proc removeNodes(el: XmlNode) =
    ## parses an XmlNode removing tags defined by `skipNodesXml`
    var
        l = el.len
        n = 0
    while n < l:
        let el = el[n]
        case el.kind:
            of xnElement:
                case el.tag:
                    of skipNodesXml:
                        el.delete(n)
                        l -= 1
                    else: n += 1
            else:
                if el.len > 0:
                    removeNodes(el)
                n += 1
    debug "amprem: el now is {$el}"



template maybeProcess(): untyped {.dirty.} =
    el.delAttr("onclick")
    if el.len != 0:
        await el.processBody(outBody, outHead, true)
    elif el.kind == VNodeKind.verbatim:
        let xEl = el.parseNode
        case xEl.tag:
            of skipNodesXml:
                el.text.setLen 0
            else:
                removeNodes(xEl)
                el.text = $xEl

proc processBody(inEl, outBody, outHead: VNode, lv = false) {.async.} =
    var
        l = inEl.len
        n = 0
    while n < l:
        let el = inEl[n]
        case el.kind:
            of skipNodes:
                inEl.delete(n)
                l -= 1
                continue
            of VNodeKind.link:
                if el.isLink(stylesheet):
                    await el.fetchStyle()
                else:
                    outBody.add el
                inEl.delete(n)
                l -= 1
            of VNodeKind.style:
                styleScript.add el[0].text
                inEl.delete(n)
                l -= 1
            of VNodeKind.script:
                if el.getAttr("type") == $ldjson:
                    outHead.add el
                inEl.delete(n)
                l -= 1
            else:
                case el.kind:
                    of VNodeKind.text, VNodeKind.verbatim: discard
                    else:
                        debug "ampbody: maybe processing {el.kind}"
                        maybeProcess
                if lv: discard
                else: outBody.add el
                n += 1

proc pre(pattern: static string): Regex {.gcsafe.} =
    var res {.threadvar.}: Regex
    res = re(pattern)
    res

proc ampPage*(tree: VNode): Future[VNode] {.gcsafe, async.} =
  ## Amp processing uses global vars and requires lock.
  assert not tree.isnil
  await ampLock[].acquire()
  defer: ampLock[].release()
  let
      inBody = tree.find(VNodeKind.body).deepcopy
      inHead = tree.find(VNodeKind.head).deepcopy
  let (outHtml, outHead, outBody) = ampTemplate()
  outHtml.setAttr("amp", "")
  for (a, v) in tree.find(html).attrs:
      outHtml.setattr(a, v)

  styleScript.setLen 0
  styleStr = ""

  await processHead(inHead, outHead)
  await processBody(inBody, outBody, outHead)

  # add remaining styles to head
  styleStr.add styleScript
      .join("\n")
      # NOTE: the replacement should be ordered from most frequent to rarest
      # # remove troublesome animations
      .replace(pre"""\s*?@(\-[a-zA-Z]+-)?keyframes\s+?.+?{\s*?.+?({.+?})+?\s*?}""", "")
      # # remove !important hints
      .replace(pre"""!important""", "")
      # remove charset since not allowed
      .replace(pre"""@charset\s+\"utf-8\"\s*;?/i""", "")

  if styleStr.len > 75000:
      raise newException(ValueError, "Style size above limit for amp pages.")

  styleScript.setLen 0
  styleElCustom.delete(0)
  styleElCustom.add verbatim(styleStr)
  return ampDoc

proc ampDir(target: string) {.error: "not implemented".} =
  if not dirExists(target):
      raise newException(OSError, fmt"Supplied target directory {target} does not exists.")


proc initAmp*() =
  ampLock = create(AsyncLock)
  ampLock[] = newAsyncLock()
  vbtmcache = newLruCache[array[5, byte], XmlNode](32)
  rootDir = SITE_PATH

  ampDoc = newVNode(VNodeKind.html)
  ampHead = newVNode(VNodeKind.head)
  ampBody = newVNode(VNodeKind.body)
  styleEl1 = newVNode(VNodeKind.style)
  styleEl2 = newVNode(VNodeKind.style)
  styleEl2Wrapper = newVNode(VNodeKind.noscript)
  ampjs = newVNode(script)
  charset = newVNode(meta)
  viewport = newVNode(meta)
  styleElCustom = newVNode(VNodeKind.style)

  filesCache = initTable[string, string]()
  styleScript = newSeq[string]()

  ampLinkEl = newVNode(VNodeKind.link)
  ampLinkEl.setAttr("rel", "amphtml")

  ampjs.setAttr("async", "")
  ampjs.setAttr("src", "https://cdn.ampproject.org/v0.js")
  charset.setAttr("charset", "utf-8")
  viewport.setAttr("name", "viewport")
  viewport.setAttr("content", "width=device-width,minimum-scale=1,initial-scale=1")

  styleEl1.setAttr("amp-boilerplate", "")
  styleEl1.add newVNode(VNodeKind.text)
  styleEl1[0].text = "body{-webkit-animation:-amp-start 8s steps(1,end) 0s 1 normal both;-moz-animation:-amp-start 8s steps(1,end) 0s 1 normal both;-ms-animation:-amp-start 8s steps(1,end) 0s 1 normal both;animation:-amp-start 8s steps(1,end) 0s 1 normal both}@-webkit-keyframes -amp-start{from{visibility:hidden}to{visibility:visible}}@-moz-keyframes -amp-start{from{visibility:hidden}to{visibility:visible}}@-ms-keyframes -amp-start{from{visibility:hidden}to{visibility:visible}}@-o-keyframes -amp-start{from{visibility:hidden}to{visibility:visible}}@keyframes -amp-start{from{visibility:hidden}to{visibility:visible}}"
  styleEl2.setAttr("amp-boilerplate", "")
  styleEl2.add newVNode(VNodeKind.text)
  styleEl2[0].text = "body{-webkit-animation:none;-moz-animation:none;-ms-animation:none;animation:none}"

  styleEl2Wrapper.add styleEl2
  styleElCustom.setAttr("amp-custom", "")
  styleElCustom.setAttr("type", "text/css")
  styleElCustom.add newVNode(VNodeKind.text)

initAmp()

proc ampLink*(path: string): VNode {.gcsafe.} =
  ampLinkEl.setAttr("href", pathLink(path, amp = (not path.startsWith("/amp")), rel = false))
  deepCopy(ampLinkEl)

# when isMainModule:
#     let file = SITE_PATH / "vps" / "index.html"
#     let p = ampPage(file)
