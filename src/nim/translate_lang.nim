import
  os,
  karax/[vdom, karaxdsl],
  strutils,
  xmltree,
  htmlparser,
  chronos,
  lrucache

import
  cfg,
  utils,
  types,
  translate_types,
  translate_tforms,
  translate_tr,
  translate_srv,
  translate

template translateVbtm(fc: FileContext; node: VNode, q: QueueDom) =
  assert node.kind == VNodeKind.verbatim
  let tree = ($node).parseHtml() # FIXME: this should be a conversion, but the conversion doesn't preserve whitespace??
  if tree.kind == xnElement and tree.tag == "document":
    tree.tag = "div"
  takeOverFields(tree.toVNode, node)
  translateIter(fc, node, vbtm = false)

template translateIter(fc: FileContext; otree; vbtm: static[bool] = true) =
  for el in otree.preorder():
    if el.kind == vdom.VNodeKind.text:
      if not el.text.isEmptyOrWhitespace and isTranslatable(el):
        translate(q.addr, el, srv)
    else:
      if el.kind in tformsTags:
        getTForms(dom)[el.kind](fc, el, file_path, url_path, pair)
      case el.kind:
        of VNodeKind.a:
          if el.hasAttr("href"):
            rewriteUrl(el, rewrite_path, fc.config.websiteDomain)
        of VNodeKind.verbatim:
          when vbtm:
            debug "dom: translating verbatim", false
            translateVbtm(fc, el, q)
        else:
          if(el.hasAttr("alt") and el.isTranslatable("alt")) or
            (el.hasAttr("title") and el.isTranslatable("title")):
            translate(q.addr, el, srv)

type DomTranslation = tuple[queue: QueueDom, node: VNode, fut: Future[bool]]
proc translateDom(fc: FileContext): Future[DomTranslation] {.async.} =
  translateEnv(dom)
  for node in otree.preorder():
    case node.kind:
      of vdom.VNodeKind.html:
        node.setAttr("lang", pair.trg)
        if pair.trg in RTL_LANGS:
          node.setAttr("dir", "rtl")
      of vdom.VNodeKind.head:
        node.add buildHtml(meta(name = "srclang", content = pair.src))
        break
      else: continue
  translateIter(fc, otree, vbtm = true)
  debug "dom: finishing translations"
  result.queue = q
  result.node = otree
  result.fut = translate(q.addr, srv, finish = true)

proc replace[T, V](fut: sink Future[T], val: sink V): Future[V] {.async.} =
  discard await fut
  return val

template withTimeout(): VNode =
  bind translateDom
  when timeout > 0:
    assert jobId != "", "trans: timeout requires a jobid."
    if jobId in translateFuts:
      # Concurrent requests can wait the same timeout number (for consistency), could be removed
      # and instead just serve the incomplete results...
      raceAndCheck(translateFuts[jobId][1], to1=timeout.milliseconds, ignore=false)
      # discard await race(translateFuts[jobId][1], sleepAsync(
      #     timeout.milliseconds))
      translateFuts[jobId][0]
    else:
      let td = await translateDom(fc)
      discard await race(td.fut, sleepAsync(timeout.milliseconds))
      if not td.fut.finished():
        debug "trans: eager translation timed out. (transId: {jobId})"
        translateFuts[jobId] = (td.node, td.fut)
        # signal that full translation is underway to js
        td.node.find(VNodeKind.head).add buildHtml(meta(name = "translation",
            content = "processing"))
      td.node
  else:
    let td = await translateDom(fc)
    discard await td.fut
    td.node

proc translateLang*(tree: vdom.VNode, file, rx: auto, lang: langPair, targetPath = "",
                    ar = emptyArt, timeout: static[int] = 0,
                        jobId = ""): Future[VNode] {.gcsafe, async.} =
  when timeout <= 0 or jobId notin translateFuts:
    let
      (filedir, relpath) = splitUrlPath(rx, file)
      t_path = if targetPath == "": filedir / lang.trg / (if relpath ==
          "": "index.html" else: relpath)
                  else: targetPath
    let fc = init(FileContext, tree, filedir, relpath, lang, t_path, config.websiteDomain)
  return withTimeout()

proc translateLang*(fc: FileContext, ar = emptyArt, timeout: static[int] = 0,
    jobId = ""): Future[VNode] {.gcsafe, async.} =
  try:
    result = withTimeout()
  except:
    logexc()
    debug "page: Translation failed."
