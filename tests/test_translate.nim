import translate_types, translate_srv, translate_misc, os, translate_lang, htmlparser, strutils,
        algorithm, sequtils, unicode, xmltree, random, strformat
import karax/vdom, times
import macros
import types, cfg, utils, cache, locktpl, html, articles, topics, search, amp, html_misc, translate, translate_lang
import server, server_types
import cligen
include ./pages.nim

import chronos

proc dotrans(): Future[string] {.async.} =
    let pair = (src: "en", trg: "pl")
    let f = getTfun(pair)
    return await f("Today is a good day to die, but tomorrow will be even better", pair)

import karax/vdom
proc dotranslation(target: string) =
    let pair = (src: "en", trg: target)
    let f = getTfun(pair)
    var q = getQueue(f, xml, pair)
    let capts = uriTuple("/vps/0/cloud-vps")

    let tree = articleTree(capts)
    # let tree = newVNode(VNodeKind.tdiv)
    # tree.add newVNode(VNodeKind.text)
    # tree[0].value = "Hello I am garfield"
    echo tree
    var fc = initFileContext(
        tree, SITE_PATH, "index.html",
        pair, SITE_PATH / pair.trg / "index.html")
    let vn = translateLang(fc)
    echo vn
    # echo vn.find(VNodeKind.main)

when isMainModule:
    server.initThread()
    dotranslation("it")
    # dispatchMulti([dotranslation])
