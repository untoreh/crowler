import nimpy
import osproc
import strutils
import strformat
import os
import tables
import sugar
import sets
import sequtils
import pathnorm
import nre
import htmlparser
import xmltree
import options
import strtabs
import uri

import cfg
import quirks
import translate_types
import translate_db
import translate_srv
import utils



const skip_class = to_hashset[string]([])
var transforms = initTable[string, TransformFunc]()
const excluded_dirs = to_hashset[string](collect(for lang in TLangs: lang.code))
const included_dirs = to_hashset[string]([])

proc link_src_to_dir(dir: string) =
    let link_path = dir / SLang.code
    if fileExists(link_path) or symlinkExists(link_path):
        logger.log(lvlWarn, fmt"Removing file {link_path}")
        removeFile(link_path)
    # NOTE: If the link_path is a directory it will fail
    createSymlink("./", link_path)
    debug "Created symlink from {dir} to {link_path}"

proc isTranslatable(el: auto): bool =
    (not el.text.isEmptyOrWhitespace) and punct_rgx in el.text

var uriVar: URI
proc rewriteUrl(el, rewrite_path, hostname: auto): string =
    parseURI(el.attrs["href"], uriVar)
    # remove initial dots from links
    uriVar.path = uriVar.path.replace(re"\.?\.?", "")
    if uriVar.host == "" or uriVar.host == hostname and
        uriVar.host.startsWith("/"):
        uriVar.path=join(rewrite_path, p)
    el.attrs["href"] = uriVar


proc translateHtml(tree, file_path, url_path, pair, slator: auto,
        hostname = WEBSITE_DOMAIN, finish = true): (Queue, XmlNode) =
    let
        tformsTags = collect(for k in transforms.keys: k).toHashSet
        rewrite_path = "/" / pair.trg
        srv = slator.name
        skip_children = 0
        q = getTfun(pair, slator).initQueue(pair, slator).some

    var otree = deepcopy(tree)

    # Set the target lang attribute at the top level
    var a: XmlAttributes
    a = otree.child("html").attrs
    if a.isnil:
        a = newStringTable()
        otree.child("html").attrs = a
    a["lang"] = pair.trg
    if pair.trg in RTL_LANGS:
        a["dir"] = "rtl"
    for el in preorder(otree):
        # skip empty nodes
        case el.kind:
            of xnText, xnVerbatimText:
                if el.text.isEmptyOrWhitespace:
                    continue
                if isTranslatable(el):
                    translate(q, el, srv)
            else:
                let t = el.tag
                if t in tformsTags:
                    transforms[t](el, file_path, url_path, pair)
                if t == "a":
                    if el.attrs.haskey("href"):
                        rewriteUrl(el, rewrite_path, hostname)
                elif (el.attrs.haskey "alt" and el.attrs["alt"].isTranslatable) or
                     (el.attrs.haskey "title" and el.attrs["title"].isTranslatable):
                    translate(q, el, srv)
    translate(q, srv, finish=finish)
    raise newException(ValueError, "")
    #

proc splitUrlPath(rx, file: auto): auto =
    let m = find(file, rx).get.captures
    (m[0], m[1])

proc translateFile(file, rx, langpairs, slator: auto, target_path = "") =
    let
        html = parseHtml(readFile(file))
        (filepath, urlpath) = splitUrlPath(rx, file)
    debug "translating file {file}"
    for pair in langpairs:
        let
            t_path = if target_path == "":
                         file_path / pair.trg / url_path
                     else:
                         target_path
            d_path = parentDir(t_path)
        createDir(d_path)
        let ot = translateHtml(html, file_path, url_path, pair, slator)
        # writeFile(t_path, ot)
        debug "writing to path {t_path}"
        # openFile(t_path, "w") do


    echo filepath, " ", urlpath


proc fileWise(path, exclusions, rx_file, langpairs, slator: auto) =
    for file in filterFiles(path, excl_dirs = exclusions, top_dirs = included_dirs):
        debug "translating {file}"
        translateFile(file, rx_file, langpairs, slator)
        debug "translation successful"

proc translateDir(path: string, service = deep_translator) =
    assert path.dirExists
    let
        dir = normalizePath(path)
        langpairs = collect(for lang in TLangs: (src: SLang.code, trg: lang.code))
        slator = initTranslator(service, source = SLang)
        rx_file = re fmt"(.*{dir}/)(.*$)"

    debug "Regexp is '(.*{dir}/)(.*$)'."
    link_src_to_dir(dir)
    fileWise(path, excluded_dirs, rx_file, langpairs, slator)

when isMainModule:
    # echo initTranslator()
    # let topic = "vps"
    translateDir(SITE_PATH)
