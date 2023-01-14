import std/[os, locks, sets, uri, strutils, strformat, sequtils, hashes, tables, xmltree, htmlparser, with],
       karax / [karaxdsl, vdom, vstyles],
       lrucache,
       chronos,
       chronos/asyncsync

import cfg,
       utils,
       nativehttp,
       html_misc,
       html_entities,
       ads

const CSS_MAX_SIZE = 75000
const skipNodes = [VNodeKind.iframe, audio, canvas, embed, video, img,
    VNodeKind.head, svg]
const skipNodesXml = ["iframe", "audio", "canvas", "embed", "video", "img",
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
    # Don't duplicate styles that appear more than once in the html
    (dupStyles, HashSet[string]),
    (ampLock, AsyncLock)
)

const skipFiles = ["bundle.css"]

proc asLocalUrl(path: string): string {.inline.} =
  $(config.websiteUrl / path.replace(SITE_PATH, ""))

proc getFile(path: string): Future[string] {.async.} =
  ## This does not actually read or save contents to storage, just holds an in memory cache
  ## and fetches from remove urls
  debug "amp: getting style file from path {path}"
  var url: string
  var fileUri: Uri
  try:
    result = filesCache[path]
  except KeyError:
    parseUri(path, fileUri)
    url =
      if fileUri.scheme.isEmptyOrWhitespace and len(fileUri.query) == 0:
        path.asLocalUrl
      else:
        path
    debug "getfile: getting file content from {url}"
    block:
      # FIXME: We can't fetch local urls because cloudflare TLS and chronhttp fail to handshake
      # ...therefore read from local files
      parseUri(url, fileUri)
      let path = SITE_PATH / fileUri.path
      try:
        if fileExists(path):
          filesCache[path] = await readfileAsync(path)
        else:
          let resp = (await get(url, proxied = false))
          checkTrue(resp.body.len > 0, "amp: body empty")
          filesCache[path] = resp.body
          return resp.body
      except:
        debug "Couldn't fetch file during amp conversion. {path}"
        return ""
    return filesCache[path]


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

proc maybeStyle(data: string) =
  if not (data in dupStyles):
    if data.len + styleStr.len < CSS_MAX_SIZE:
      dupStyles.incl data
      styleStr.add data
    else:
      warn "amp: skipping style {data.len:.10}..."

proc fetchStyle(el: VNode) {.async.} =
  var data: string
  let src = cast[string](el.getAttr("href"))
  data.add if src.startsWith("/"):
      let path = rootDir / src.strip(leading = true, chars = {'/'})
      await getFile(path)
  else:
      await getFile(src)
  data.maybeStyle

template processNoScript() =
  if level == 0:
    let elNoScript = newVNode(VNodeKind.noscript)
    await processHead(el, elNoScript, level = 1)
    if len(elNoscript) > 0:
      outHead.add elNoScript

proc processHead(inHead: VNode, outHead: VNode, level = 0) {.async.} =
  var canonicalUnset = level == 0
  debug "iterating over {inHead.kind}"
  for el in inHead.preorder(withStyles = true):
    case el.kind:
      of VNodeKind.text, skipNodes:
        continue
      of VNodeKind.style:
        if el.len > 0:
          el[0].text.maybeStyle
      of VNodeKind.link:
        if canonicalUnset and el.isLink(canonical):
          outHead.add el
          canonicalUnset = false
        elif el.isLink(stylesheet) and (not ("flags-sprite" in el.getattr("href"))):
          await el.fetchStyle()
        elif el.isLink(preload) and el.getattr("as") == "style":
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
        let data = el.toXmlNode
        if data.kind == xnElement:
          if data.tag == "noscript":
            processNoScript()
          elif data.tag == "script":
            continue
          elif data.tag == "style":
            if data.len > 0:
              data[0].text.maybeStyle
          else:
            outHead.add el
      of VNodekind.noscript:
        processNoScript()
      else:
        debug "amphead: adding element {el.kind} to outHead."
        outHead.add el

# proc parseNode(node: VNode): XmlNode =
#   let
#     s = node.text
#     tree = try:
#              vbtmcache[s.key]
#            except:
#              vbtmcache[s.key] = parseHtml(s)
#              vbtmcache[s.key]
#   return deepcopy(tree)

# proc removeNodes(el: XmlNode) =
#   ## parses an XmlNode removing tags defined by `skipNodesXml`
#   var
#     l = el.len
#     n = 0
#   while n < l:
#     let el = el[n]
#     case el.kind:
#       of xnElement:
#         case el.tag:
#           of skipNodesXml:
#             el.delete(n)
#             l -= 1
#           else: n += 1
#       else:
#         if el.len > 0:
#           removeNodes(el)
#         n += 1
#   debug "amprem: el now is {$el}"


const globalAttrs = ["accessKey", "class", "contenteditable", "dir",
    "draggable", "hidden", "id", "lang", "spellcheckl", "style", "tabindex",
    "title", "translate"].toHashSet
const aTagAttrs = ["download", "href", "hreflang", "media", "ping",
    "referrerpolicy", "rel", "target", "type"].toHashSet
template processAttrs(el: VNode): untyped {.dirty.} =
  el.delAttr("onclick")
  case el.kind:
    of VNodeKind.a:
      var attrs: seq[string]
      for (k, v) in el.attrs:
        case k:
          of "target":
            attrs.add [k, "_blank"] # `target` attr can only be _blank
          of "href":
            if v.startsWith("javascript:"):
              continue
            else:
              attrs.add [k, v]
          else:
            if (k.startsWith("on") and k.len > 2) or
               k.startsWith("xml") or
               k.startsWith("i-amp-"):
              continue
            elif k notin aTagAttrs or k notin globalAttrs:
              continue
            attrs.add [k, v]
      el.attrs = attrs
    else: discard

template processAttrs(el: XmlNode): untyped {.dirty.} =
  if el.kind == xnElement:
    el.delAttr("onclick")
    case el.tag:
      of "a":
        if el.hasAttr("target"): # `target` attr can only be _blank
          el.setAttr("target", "_blank")
        el.delAttr("alt") # Can't have `alt` attributes
      else: discard

template process(el: VNode, after: untyped): bool =
  var isprocessed = true
  case el.kind:
    of skipNodes: discard
    of VNodeKind.link:
      if el.isLink(stylesheet):
        await el.fetchStyle()
      else:
        outBody.add el
    of VNodeKind.style:
      el.text.maybeStyle
      el.text = ""
    of VNodeKind.script:
      if el.getAttr("type") == $ldjson:
        outHead.add el
      el.text = ""
    of VNodeKind.form:
      el.setAttr("amp-form", "")
    else:
      isprocessed = false
  if isprocessed:
    after
  isprocessed

template process(el: VNode): bool =
  el.process:
    discard

proc processBody(inEl, outBody, outHead: VNode, lv = false) {.async.} =
  var
    l = inEl.len
    n = 0
  while n < l:
    let el = inEl[n]
    let isprocessed = el.process:
      inEl.delete(n)
      l -= 1
    if not isprocessed:
      if el.kind == VNodeKind.verbatim:
        var processed: string
        let xEl = el.toXmlNode
        if xEl.kind == xnElement and xEl.tag ==
            "document": # verbatim included a list of tags, process each one singularly
          for k in xEl:
            processAttrs(k)
            let vnK = k.toVNode
            if (not process(vnK)):
              await vnK.processBody(outBody, outHead, true)
            processed.add vnK.raw
        elif xEl.kind != xnText:
          processAttrs(xEl)
          let vnEl = xEl.toVNode
          if (not process(vnEl)):
            await vnEl.processBody(outBody, outHead, true)
          processed.add vnEl.raw
        else:
          processed.add xEl.text
        el.text = processed
      else:
        processAttrs(el)
        logall "ampbody: recursing {el.kind}"
        await el.processBody(outBody, outHead, true)
      if lv:
        discard
      else:
        outBody.add el
      n += 1

proc pre(pattern: static string): Regex {.gcsafe.} =
  var res {.threadvar.}: Regex
  res = re(pattern)
  res

proc ampPage*(tree: VNode): Future[VNode] {.gcsafe, async.} =
  ## Amp processing uses global vars and requires lock.
  debug "amp: start"
  checkNil tree
  # since using globals we have to lock throughout the page generation
  await ampLock.acquire()
  styleStr = ""
  dupStyles.clear()
  defer: ampLock.release()
  let
    inBody = tree.find(VNodeKind.body).deepcopy
    inHead = tree.find(VNodeKind.head).deepcopy
  let (outHtml, outHead, outBody) = ampTemplate()
  outHtml.setAttr("amp", "")
  for (a, v) in tree.find(html).attrs:
    outHtml.setattr(a, v)


  await processHead(inHead, outHead)
  await processBody(inBody, outBody, outHead)

  # add remaining styles to head
  styleStr = styleStr
    # .join("\n")
    # NOTE: the replacement should be ordered from most frequent to rarest
    # # remove troublesome animations
    .replace(pre"""\s*?@(\-[a-zA-Z]+-)?keyframes\s+?.+?{\s*?.+?({.+?})+?\s*?}""", "")
    # # remove !important hints
    .replace(pre"""!important""", "")
    # remove charset since not allowed
    .replace(pre"""@charset\s+\"utf-8\"\s*;?/i""", "")

  if unlikely(styleStr.len > CSS_MAX_SIZE):
    raise newException(ValueError, fmt"Style size above limit for amp pages. {styleStr.len}")

  styleElCustom.delete(0)
  styleElCustom.add verbatim(styleStr)
  return ampDoc

proc ampDir(target: string) {.error: "not implemented".} =
  if not dirExists(target):
    raise newException(OSError, fmt"Supplied target directory {target} does not exists.")


proc initAmpImpl() =
  ampLock = newAsyncLock()
  vbtmcache = newLruCache[array[5, byte], XmlNode](32)
  dupStyles = initHashSet[string]()
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

proc initAmp*() =
  try:
    initAmpImpl()
  except:
    logexc()
    qdebug "server: failed to initAmp"

proc ampLink*(path: string): VNode {.gcsafe.} =
  result = newVNode(VNodeKind.link)
  result.setAttr("rel", "amphtml")
  result.setAttr("href", pathLink(path, amp = (not path.startsWith("/amp")), rel = false))

