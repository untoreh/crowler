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
       hashes

from sonic {.all.} import SonicServerError
export SonicServerError

import
    types,
    server_types,
    utils,
    cfg,
    html_misc,
    translate_db,
    translate_types,
    # translate_lang,
    translate_srv,
    cache,
    topics

var
    snc {.threadvar.}: Sonic
    sncc {.threadvar.}: Sonic
    sncq {.threadvar.}: Sonic
let Language = pyImport("langcodes").Language

proc closeSonic() =
    debug "sonic: closing"
    try:
        discard snc.quit()
        discard sncc.quit()
        discard sncq.quit()
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

proc toISO3(lang: string): string =
    Language.get(if lang == "": SLang.code
                 else: lang).to_alpha3().to(string)

proc sanitize*(s: string): string =
    ## Replace new lines for search queries and ingestion
    s.replace(sre "\n|\r", "")

proc push(capts: UriCaptures, content: string) =
    ## Push the contents of an article page to the search database
    if not snc.push(WEBSITE_DOMAIN,
             capts.topic,
             join([capts.page, capts.art], "/"),
             content,
             lang = capts.lang.toISO3):
        let f = open(SONIC_BACKLOG, fmAppend)
        defer: f.close()
        let l = join([capts.topic, capts.page, capts.art, capts.lang], ",")
        writeLine(f, l)

proc push(relpath: var string) =
    relpath.removeSuffix('/')
    let
        fpath = relpath.fp
        capts = uriTuple(relpath)
        content = if htmlCache[][fpath] != "":
                      let page = htmlCache[].get(fpath).parseHtml
                      assert capts.lang == "" or page.findel("html").getAttr("lang") == (capts.lang)
                      page.findclass(HTML_POST_SELECTOR).innerText()
                  else:
                      getArticleContent(capts.topic, capts.page, capts.art)
    if content == "":
        warn "search: content matching path {relpath} not found."
    else:
        push(capts, content.sanitize)
        # sncc.trigger("consolidate")

proc resume() =
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
        push(relpath)
    writeFile(SONIC_BACKLOG, "")

proc query*(topic: string, keywords: string, lang: string = SLang.code): seq[string] =
    ## translate the query to source language, because we only index
    ## content in source language
    ## the resulting entries are in the form {page}/{slug}
    let
        kws = if lang in TLangsTable:
                  # echo "ok"
                  let lp = (src: lang, trg: SLang.code)
                  let translate = getTfun(lp)
                  # echo "?? ", translate(keywords, lp)
                  something translate(keywords, lp), keywords
              else: keywords
    debug "KWS: {kws}, KEYS: {keywords}"
    sncq.query(WEBSITE_DOMAIN, topic, kws, lang = SLang.code.toISO3, limit = 10)

proc suggest*(topic, input: string): seq[string] =
    # Partial inputs language can't be handled if we
    # only injest the source language into sonic
    debug "suggest: topic: {topic}, input: {input}"
    try:
        return sncq.suggest(WEBSITE_DOMAIN, topic, input)
    except:
        debug "suggest: {getCurrentExceptionMsg()}, {getCurrentException().name}"
        closeSonic()
        initSonic()
        discard

when isMainModule:
    var relpath = "/web/0/is-hosting-your-wordpress-website-on-aws-a-good-idea"
    initSonic()
    let hc = initHtmlCache()
    discard snc.flush(WEBSITE_DOMAIN)
    htmlCache = hc.unsafeAddr
    push(relpath)
    discard sncc.trigger("consolidate")
    echo suggest("web", "web host")
