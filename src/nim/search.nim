import std/[exitprocs, monotimes, os, htmlparser, xmltree, parseutils, strutils, uri, hashes],
       nimpy,
       chronos

from unicode import runeSubStr, validateUtf8

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
  articles,
  json

pygil.globalAcquire()
pyObjPtr(
  (Language, pyImport("langcodes").Language),
  (pySonic, pyImport("sonicsearch")),
  )
# pyObjPtr((DetectLang, pyImport("translator").detect))
pygil.release()

const defaultLimit = 10
const bufsize = 20000 - 256 # FIXME: ingestClient.bufsize returns 0...

when not defined(release):
  import std/locks
  var pushLock: ptr AsyncLock

proc isopen(): bool {.withLocks: [pyGil].} =
  try: pySonic[].isopen().to(bool)
  except: false

proc toISO3(lang: string): Future[string] {.async.} =
  withPyLock:
    result = Language[].get(if lang == "": SLang.code
                      else: lang).to_alpha3().to(string)

proc sanitize*(s: string): string =
  ## Replace new lines for search queries and ingestion
  s.replace(sre "\n|\r", "").replace("\"",
      "\\\"") # FIXME: this should be done by sonic module

proc addToBackLog(capts: UriCaptures) =
  {.cast(gcsafe).}:
    let f = open(config.sonicBacklog, fmAppend)
    defer: f.close()
    let l = join([capts.topic, capts.page, capts.art, capts.lang], ",")
    writeLine(f, l)

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
      var j: PyObject
      withPyLock:
        j = pySched[].apply(
          pySonic[].push,
          config.websiteDomain,
          "default", # TODO: Should we restrict search to `capts.topic`?
          key,
          cnt,
          lang = if capts.lang != "en": lang else: ""
          )
      j = await j.pywait()
      withPyLock:
        pushed = not pyisnone(j) and j.to(bool)
      when not defined(release):
        if not pushed:
          capts.addToBackLog()
          break
    except Exception:
      logexc()
      debug "sonic: couldn't push content, \n {capts} \n {key} \n {cnt}"
      when not defined(release):
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
  let content =
    block:
      let cached = pageCache.getUnchecked(fpath)
      if cached != "":
        let page = cached.parseHtml
        assert capts.lang == "" or page.findel("html").getAttr("lang") == (capts.lang)
        page.findclass(HTML_POST_SELECTOR).innerText()
      else:
        if capts.art != "": await getArticleContent(capts.topic, capts.page, capts.art)
        else: ""
  if content == "":
    warn "search: content matching path {vrelpath} not found."
  else:
    await push(capts, content.sanitize)

when not defined(release):
  proc resumeSonic() {.async.} =
    ## Push all backlogged articles to search database
    withPyLock:
      assert isopen()
    for l in lines(config.sonicBacklog):
      let
        s = l.split(",")
        topic = s[0]
        page = s[1]
        slug = s[2]
        lang = s[3]
      var relpath = lang / topic / page / slug
      await push(relpath)
    await writeFileAsync(config.sonicBacklog, "")


type
  SonicQueryArgsTuple = tuple[topic: string, keywords: string, lang: string, limit: int]
  SonicMessageTuple = tuple[args: SonicQueryArgsTuple, id: MonoTime]
  SonicMessage = ptr SonicMessageTuple

when false:
  proc translateKws(kws: string, lang: string): Future[string] {.async.} =
    if lang in TLangsTable and lang != "en":
      # echo "ok"
      let lp = (src: lang, trg: SLang.code)
      # echo "?? ", translate(keywords, lp)
      var tkw: string
      tkw = await callTranslator(kws, lp)
      something tkw, kws
    else: kws

proc querySonic(msg: SonicMessage): Future[seq[string]] {.async.} =
  ## translate the query to source language, because we only index
  ## content in source language
  ## the resulting entries are in the form {page}/{slug}
  let (topic, keywords, lang, limit) = msg.args
  # FIXME: this is too expensive
  # let kws = await translateKws(keywords, lang)
  # logall "sonic: kws -- {kws}, query -- {keywords}"
  logall "sonic: query -- {keywords}"
  let lang3 = await SLang.code.toISO3
  withPyLock:
    let res = pySonic[].query(config.websiteDomain, "default", keywords, lang = lang3, limit = limit)
    if not pyisnone(res):
      let s = res.pyToSeqStr()
      return s

proc suggestSonic(msg: SonicMessage): Future[seq[string]] {.async.} =
  # Partial inputs language can't be handled if we
  # only ingestClient the source language into sonic
  let (topic, input, lang, limit) = msg.args
  logall "suggest: topic: {topic}, input: {input}"
  withPyLock:
    let sug = pySonic[].suggest(config.websiteDomain, "default", input.split[^1], limit = limit)
    if not pyisnone(sug):
      let s = sug.pyToSeqStr()
      return s

proc deleteFromSonic*(capts: UriCaptures): int =
  ## Delete an article from sonic db
  let key = join([capts.topic, capts.page, capts.art], "/")
  syncPyLock:
    discard pySonic[].flush(config.websiteDomain, object_name = key)

const pushLogFile = "/tmp/sonic_push_log.json"
proc readPushLog(): Future[JsonNode] {.async.} =
  if fileExists(pushLogFile):
    let log = await readFileAsync(pushLogFile)
    result = log.parseJson
  else:
    result = newJObject()

proc writePushLog(log: JsonNode) {.async.} =
  await writeFileAsync(pushLogFile, $log)

proc pushAllSonic*() {.async.} =
  syncTopics()
  var total, c, pagenum: int
  let pushLog = await readPushLog()
  if pushLog.len == 0:
    withPyLock:
      discard pySonic[].flush(config.websiteDomain)
  defer:
    withPyLock:
      discard pySonic[].consolidate()
  for (topic, state) in topicsCache:
    if topic notin pushLog:
      pushLog[topic] = %0
    await pygil.acquire
    defer: pygil.release
    let done = state.group["done"]
    for page in done:
      pagenum = ($page).parseint
      c = len(done[page])
      if pushLog[topic].to(int) >= pagenum:
        continue
      var futs: seq[Future[void]]
      for n in 0..<c:
        let ar = done[page][n]
        if ar.isValidArticlePy:
          var relpath = getArticlePath(ar, topic)
          relpath.removeSuffix("/")
          let
            capts = uriTuple(relpath)
            content = ar.pyget("content").sanitize
          echo "pushing ", relpath
          futs.add push(capts, content)
          total.inc
      pygil.release
      await allFutures(futs)
      pushLog[topic] = %pagenum
      await writePushLog(pushLog)
      await pygil.acquire
  info "Indexed search for {config.websiteDomain} with {total} objects."

from chronos/timer import seconds, Duration

proc query*(topic: string, keywords: string, lang: string = SLang.code,
            limit = defaultLimit): Future[seq[string]] {.async.} =
  ## Thread safe sonic query
  if unlikely(keywords.len == 0):
    return
  var msg: SonicMessageTuple
  msg.args.topic = topic
  msg.args.keywords = keywords
  msg.args.lang=  lang
  msg.args.limit = limit
  msg.id = getMonoTime()
  return await querySonic(msg.addr)

# import quirks # required by py DetectLang
proc suggest*(topic, input: string, limit = defaultLimit): Future[seq[string]] {.async.} =
  if unlikely(input.len == 0):
    return
  var msg: SonicMessageTuple
  msg.args.topic = topic
  msg.args.keywords = input
  # var dlang: string
  # withPyLock:
  #   dlang = DetectLang[](input).to(string)
  # msg.args.lang = await toISO3(dlang)
  msg.args.limit = limit
  msg.id = getMonoTime()
  return await suggestSonic(msg.addr)

proc connectSonic(reconnect=false) =
  var notConnected: bool
  syncPyLock:
    discard pySonic[].connect(SONIC_ADDR, SONIC_PORT, SONIC_PASS, reconnect=reconnect)
  syncPyLock:
    doassert pySonic[].is_connected.to(bool), "Is Sonic running?"

template restartSonic(what: string) {.dirty.} =
  logexc()
  if e is OSError:
    connectSonic(reconnect=true)

proc initSonic*() {.gcsafe.} =
  when not defined(release):
    pushLock = create(AsyncLock)
    pushLock[] = newAsyncLock()
  connectSonic()
  syncPyLock:
    discard pysched[].initPool()

when isMainModule:
  initPy()
  syncPyLock:
    discard pysched[].initPool()
  initSonic()
  waitFor pushAllSonic()
  # debug "nice"
  # let q = waitFor query("mini", "crossword", "it")
  # echo q
  # let qq = waitFor query("mini", "mini", "es")
  # echo qq
  # debug "done"
  # let qq = waitFor suggest("mini", "mini")
  # echo qq
  # push(relpath)
  # discard controlClient.trigger("consolidate")
  # echo suggest("web", "web host")
