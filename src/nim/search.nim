import strutils,
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

import threading/channels
import std/isolation

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

pygil.globalAcquire()
pyObjPtr(
  (Language, pyImport("langcodes").Language),
  (pySonic, pyImport("sonicsearch")),
  )
# pyObjPtr((DetectLang, pyImport("translator").detect))
pygil.release()

const defaultLimit = 10
const bufsize = 20000 - 256 # FIXME: ingestClient.bufsize returns 0...

proc isopen(): bool {.withLocks: [pyGil].} =
  try: pySonic[].isopen().to(bool)
  except CatchableError: false

proc toISO3(lang: string): Future[string] {.async.} =
  withPyLock:
    result = Language[].get(if lang == "": SLang.code
                      else: lang).to_alpha3().to(string)

proc sanitize*(s: string): string =
  ## Replace new lines for search queries and ingestion
  s.replace(sre "\n|\r", "").replace("\"",
      "\\\"") # FIXME: this should be done by sonic module

proc addToBackLog(capts: UriCaptures) =
  let f = open(SONIC_BACKLOG, fmAppend)
  defer: f.close()
  let l = join([capts.topic, capts.page, capts.art, capts.lang], ",")
  writeLine(f, l)

var pushLock: ptr AsyncLock
import std/locks
proc push*(capts: UriCaptures, content: string) {.async.} =
  ## Push the contents of an article page to the search database
  ## NOTE: NOT thread safe
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
      var pushed: bool
      withPyLock:
        pushed = pySonic[].push(WEBSITE_DOMAIN,
                "default", # TODO: Should we restrict search to `capts.topic`?
          key,
          cnt,
          lang = if capts.lang != "en": lang else: "").to(bool)
      if not pushed:
        capts.addToBackLog()
        break
    except CatchableError:
      let e = getCurrentException()[]
      debug "sonic: couldn't push content, {e} \n {capts} \n {key} \n {cnt}"
      capts.addToBackLog()
      block:
        var f: File
        try:
          await pushLock[].acquire
          f = open("/tmp/sonic_debug.log", fmWrite)
          write(f, cnt)
        finally:
          pushLock[].release
          if not f.isnil:
            f.close()
      break

proc push*(relpath: string) {.async.} =
  var vrelpath = relpath
  vrelpath.removeSuffix('/')
  let
    fpath = vrelpath.fp()
    capts = uriTuple(vrelpath)
  let content = if pageCache[][fpath.hash] != "":
                      let page = pageCache[].get(fpath.hash).parseHtml
                      assert capts.lang == "" or page.findel("html").getAttr(
                          "lang") == (capts.lang)
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
  withPyLock:
    assert isopen()
  for l in lines(SONIC_BACKLOG):
    let
      s = l.split(",")
      topic = s[0]
      page = s[1]
      slug = s[2]
      lang = s[3]
    var relpath = lang / topic / page / slug
    await push(relpath)
  await writeFileAsync(SONIC_BACKLOG, "")

import std/monotimes
import locktplasync
asyncLockedStore(Table)
type
  SonicQueryArgsTuple = tuple[topic: string, keywords: string, lang: string, limit: int]
  SonicMessageTuple = tuple[args: SonicQueryArgsTuple, id: MonoTime]
  SonicMessage = ptr SonicMessageTuple

proc querySonic(msg: SonicMessage): Future[seq[string]] {.async.} =
  ## translate the query to source language, because we only index
  ## content in source language
  ## the resulting entries are in the form {page}/{slug}
  let (topic, keywords, lang, limit) = msg.args
  let kws = if lang in TLangsTable and lang != "en":
                # echo "ok"
                let lp = (src: lang, trg: SLang.code)
                # echo "?? ", translate(keywords, lp)
                var tkw: string
                tkw = await callTranslator(keywords, lp)
                something tkw, keywords
            else: keywords
  logall "query: kws -- {kws}, keys -- {keywords}"
  let lang3 = await SLang.code.toISO3
  withPyLock:
    let res = pySonic[].query(WEBSITE_DOMAIN, "default", kws, lang = lang3, limit = limit)
    if not pyisnone(res):
      let s = res.pyToSeqStr()
      return s

proc suggestSonic(msg: SonicMessage): Future[seq[string]] {.async.} =
  # Partial inputs language can't be handled if we
  # only ingestClient the source language into sonic
  let (topic, input, lang, limit) = msg.args
  logall "suggest: topic: {topic}, input: {input}"
  withPyLock:
    let sug = pySonic[].suggest(WEBSITE_DOMAIN, "default", input.split[^1], limit = limit)
    if not pyisnone(sug):
      let s = sug.pyToSeqStr()
      return s

proc deleteFromSonic*(capts: UriCaptures): int =
  ## Delete an article from sonic db
  let key = join([capts.topic, capts.page, capts.art], "/")
  syncPyLock:
    discard pySonic[].flush(WEBSITE_DOMAIN, object_name = key)

proc pushAllSonic*(clear = true) {.async.} =
  await syncTopics()
  if clear:
    withPyLock:
      discard pySonic[].flush(WEBSITE_DOMAIN)
  for (topic, state) in topicsCache:
    let done = state.group[]["done"]
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
  withPyLock:
    discard pySonic[].trigger("consolidate")

from chronos/timer import seconds, Duration

proc query*(topic: string, keywords: string, lang: string = SLang.code,
            limit = defaultLimit): Future[seq[string]] {.async.} =
  ## Thread safe sonic query
  if unlikely(keywords.len == 0):
    return
  let msg = create(SonicMessageTuple)
  msg.args.topic = topic
  msg.args.keywords = keywords
  msg.args.lang=  lang
  msg.args.limit = limit
  msg.id = getMonoTime()
  return await querySonic(msg)

# import quirks # required by py DetectLang
proc suggest*(topic, input: string, limit = defaultLimit): Future[seq[string]] {.async.} =
  if unlikely(input.len == 0):
    return
  let msg = create(SonicMessageTuple)
  msg.args.topic = topic
  msg.args.keywords = input
  # var dlang: string
  # withPyLock:
  #   dlang = DetectLang[](input).to(string)
  # msg.args.lang = await toISO3(dlang)
  msg.args.limit = limit
  msg.id = getMonoTime()
  return await suggestSonic(msg)

proc connectSonic(reconnect=false) =
  var notConnected: bool
  syncPyLock:
    discard pySonic[].connect(SONIC_ADDR, SONIC_PORT, SONIC_PASS, reconnect=reconnect)
  syncPyLock:
    doassert pySonic[].is_connected.to(bool), "Is Sonic running?"

template restartSonic(what: string) {.dirty.} =
  let e = getCurrentException()[]
  let name = getCurrentException().name
  debug what, ": {e}, {name}"
  if e is OSError:
    connectSonic(reconnect=true)

proc initSonic*() {.gcsafe.} =
  pushLock = create(AsyncLock)
  pushLock[] = newAsyncLock()
  connectSonic()

when isMainModule:
  initSonic()
  # pushAllSonic()
  debug "nice"
  let q = waitFor query("mini", "crossword", "it")
  echo q
  let qq = waitFor query("mini", "mini", "es")
  echo qq
  debug "done"
  # let qq = waitFor suggest("mini", "mini")
  # echo qq
  # push(relpath)
  # discard controlClient.trigger("consolidate")
  # echo suggest("web", "web host")
