import sonic,
       strutils,
       nimpy,
       std/exitprocs,
       os,
       nre,
       htmlparser,
       xmltree,
       parseutils,
       uri,
       hashes,
       chronos
from unicode import runeSubStr, validateUtf8

from sonic {.all.} import SonicServerError
export SonicServerError

import
    types,
    server_types,
    utils,
    cfg,
    translate_db,
    translate_types,
    # translate_lang,
    translate_srv,
    cache,
    topics,
    articles

var
    snc {.threadvar.}: Sonic
    sncc {.threadvar.}: Sonic
    sncq {.threadvar.}: Sonic

pygil.globalAcquire()
let Language = pyImport("langcodes").Language
pygil.release()

const defaultLimit = 10
const bufsize = 20000 - 256 # FIXME: snc.bufsize returns 0...

proc closeSonic() =
    debug "sonic: closing"
    for c in [snc, sncc, sncq]:
        if not c.isnil:
            try: discard c.quit()
            except: discard

addExitProc(closeSonic)

proc isopen(): bool =
    try: snc.ping()
    except: false

proc initSonic*() {.gcsafe.} =
    if snc.isnil or not isopen():
        try:
            debug "sonic: init"
            snc = open(SONIC_ADDR, SONIC_PORT, SONIC_PASS, SonicChannel.Ingest)
            sncc = open(SONIC_ADDR, SONIC_PORT, SONIC_PASS, SonicChannel.Control)
            sncq = open(SONIC_ADDR, SONIC_PORT, SONIC_PASS, SonicChannel.Search)
            # addExitProc(closeSonic)
        except:
            qdebug "Couldn't init Sonic connection to {SONIC_ADDR}:{SONIC_PORT}."
    doassert not snc.isnil, "Is Sonic running?"

proc toISO3(lang: string): Future[string] {.async.} =
    if pygil.locked:
        return Language.get(if lang == "": SLang.code
                    else: lang).to_alpha3().to(string)
    else:
        withPyLock:
            return Language.get(if lang == "": SLang.code
                        else: lang).to_alpha3().to(string)

proc sanitize*(s: string): string =
    ## Replace new lines for search queries and ingestion
    s.replace(sre "\n|\r", "").replace("\"", "\\\"") # FIXME: this should be done by sonic module

proc addToBackLog(capts: UriCaptures) =
    let f = open(SONIC_BACKLOG, fmAppend)
    defer: f.close()
    let l = join([capts.topic, capts.page, capts.art, capts.lang], ",")
    writeLine(f, l)

proc push*(capts: UriCaptures, content: string) {.async.} =
    ## Push the contents of an article page to the search database
    var ofs = 0
    while ofs <= content.len:
        let view = content[ofs..^1]
        let key = join([capts.topic, capts.page, capts.art], "/")
        let cnt = runeSubStr(view, 0, min(view.len, bufsize - key.len))
        ofs += cnt.len
        if cnt.len == 0:
            break
        try:
            let lang = await capts.lang.toISO3
            if not snc.push(WEBSITE_DOMAIN,
                    "default", # TODO: Should we restrict search to `capts.topic`?
                    key,
                    cnt,
                    lang = if capts.lang != "en": lang else: ""):
                capts.addToBackLog()
                break
        except:
            debug "sonic: couldn't push content, {getCurrentExceptionMsg()} \n {capts} \n {key} \n {cnt}"
            capts.addToBackLog()
            block:
                let f = open("/tmp/sonic_debug.log", fmWrite)
                defer: f.close()
                write(f, cnt)
            break

proc push*(relpath: string) {.async.} =
    var vrelpath = relpath
    vrelpath.removeSuffix('/')
    let
        fpath = vrelpath.fp()
        capts = uriTuple(vrelpath)
    let content = if pageCache[][fpath.hash] != "":
                      let page = pageCache[].get(fpath.hash).parseHtml
                      assert capts.lang == "" or page.findel("html").getAttr("lang") == (capts.lang)
                      page.findclass(HTML_POST_SELECTOR).innerText()
                  else:
                      if capts.art != "":
                        await getArticleContent(capts.topic, capts.page, capts.art)
                      else: ""
    if content == "":
        warn "search: content matching path {vrelpath} not found."
    else:
        await push(capts, content.sanitize)

proc resumeSonic() {.async.} =
    ## Push all backlogged articles to search database
    assert (not snc.isnil)
    for l in lines(SONIC_BACKLOG):
        let
            s = l.split(",")
            topic = s[0]
            page = s[1]
            slug = s[2]
            lang = s[3]
        var relpath = lang / topic / page / slug
        await push(relpath)
    writeFile(SONIC_BACKLOG, "")

proc query*(topic: string, keywords: string, lang: string = SLang.code, limit = defaultLimit): Future[seq[string]] {.async.} =
    ## translate the query to source language, because we only index
    ## content in source language
    ## the resulting entries are in the form {page}/{slug}
    let
        kws = if lang in TLangsTable:
                  # echo "ok"
                  let lp = (src: lang, trg: SLang.code)
                  let translate = getTfun(lp)
                  # echo "?? ", translate(keywords, lp)
                  let tkw = await translate(keywords, lp)
                  something tkw, keywords
              else: keywords
    logall "query: kws -- {kws}, keys -- {keywords}"
    try:
        let lang = await SLang.code.toISO3
        return sncq.query(WEBSITE_DOMAIN, "default", kws, lang = lang, limit = limit)
    except:
        debug "query: failed {getCurrentExceptionMsg()} "
        return newSeq[string]()

proc suggest*(topic, input: string, limit = defaultLimit): Future[seq[string]] {.async.} =
    # Partial inputs language can't be handled if we
    # only injest the source language into sonic
    logall "suggest: topic: {topic}, input: {input}"
    try:
        return sncq.suggest(WEBSITE_DOMAIN, "default", input.split[^1], limit = limit)
    except:
        debug "suggest: {getCurrentExceptionMsg()}, {getCurrentException().name}"
        closeSonic()
        initSonic()
        discard

proc deleteFromSonic*(capts: UriCaptures): int =
    ## Delete an article from sonic db
    let key = join([capts.topic, capts.page, capts.art], "/")
    snc.flush(WEBSITE_DOMAIN, object_name=key)

proc pushAllSonic*(clear=true) {.async.} =
    await syncTopics()
    if clear:
        discard snc.flush(WEBSITE_DOMAIN)
    for (topic, state) in topicsCache:
        let done = state.group["done"]
        for page in done:
            var c = len(done[page])
            for n in 0..<c:
                let ar = done[page][n]
                if not pyisnone(ar):
                    var relpath = getArticlePath(ar, topic)
                    relpath.removeSuffix("/")
                    let
                        capts = uriTuple(relpath)
                        content = ar.pyget("content").sanitize
                    echo "pushing ", relpath
                    await push(capts, content)
    discard sncc.trigger("consolidate")

when isMainModule:
    initSonic()
    pushAllSonic()

    echo waitFor query("mini", "crossword")
    # push(relpath)
    # discard sncc.trigger("consolidate")
    # echo suggest("web", "web host")
