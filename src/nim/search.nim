import std/[exitprocs, monotimes, os, htmlparser, xmltree, parseutils, strutils, uri, hashes],
       nimpy,
       chronos

from unicode import runeSubStr, validateUtf8
from vendor/libsonic as sonic import nil


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


const defaultLimit = 10
const bufsize = 20000 - 256 # FIXME: ingestClient.bufsize returns 0...
let
  defaultBucketStr = cstring("default")
  defaultBucket = defaultBucketStr[0].unsafeAddr
  emptyCStrObj = cstring("")
  emptyCStr = emptyCStrObj[0].unsafeAddr
  hostStr = cstring(SONIC_ADDR & ":" & $SONIC_PORT)
  host = hostStr[0].unsafeAddr
  passStr = cstring(SONIC_PASS)
  pass = passStr[0].unsafeAddr

var conn: sonic.Connection

type
  SonicMessageKind = enum query, sugg
  SonicQueryArgsTuple = tuple[col: string, topic: string, keywords: string, lang: string, limit: int]
  SonicMessageTuple = tuple[args: SonicQueryArgsTuple, kind: SonicMessageKind,
      o: ptr[seq[string]], id: MonoTime]
  SonicMessage = ptr SonicMessageTuple

var
  sonicThread: Thread[void]
  sonicIn: AsyncPColl[SonicMessage]
  sonicOut: AsyncTable[SonicMessage, bool]
  futs {.threadvar.}: seq[Future[void]]

template cptr(s: string): ptr[char] =
  if likely(s.len > 0): s[0].unsafeAddr
  else: emptyCStr

when not defined(release):
  import std/locks
  var pushLock: ptr AsyncLock

proc isopen(): bool =
  try: sonic.is_open(conn)
  except: false

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
      let pushed = sonic.pushx(
        conn,
        config.websiteDomain.cptr,
        defaultBucket, # TODO: Should we restrict search to `capts.topic`?
        key = key.cptr,
        cnt = cnt.cptr,
        lang = capts.lang.cptr
        )
      when not defined(release):
        if not pushed:
          capts.addToBackLog()
          break
    except:
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

proc querySonic(msg: SonicMessage) {.async.} =
  ## translate the query to source language, because we only index
  ## content in source language
  ## the resulting entries are in the form {page}/{slug}
  let (col, topic, keywords, lang, limit) = msg.args
  # FIXME: this is too expensive
  # let kws = await translateKws(keywords, lang)
  # logall "sonic: kws -- {kws}, query -- {keywords}"
  logall "sonic: query -- {keywords}"
  let res = sonic.query(conn, col.cptr, defaultBucket,
                        keywords.cptr, lang = lang.cptr, limit = limit.csize_t)
  if not res.isnil:
    defer: sonic.destroy_response(res)
    for s in cast[cstringArray](res).cstringArrayToSeq():
      msg.o[].add s
  sonicOut[msg] = true

proc suggestSonic(msg: SonicMessage) {.async.} =
  # Partial inputs language can't be handled if we
  # only ingestClient the source language into sonic
  let (col, topic, input, lang, limit) = msg.args
  logall "suggest: topic: {topic}, input: {input}"
  let kw = input.split[^1]
  let sug = sonic.suggest(conn, col.cptr, defaultBucket,
                          kw.cptr, limit = limit.csize_t)
  if not sug.isnil:
    defer: sonic.destroy_response(sug)
    for s in cast[cstringArray](sug).cstringArrayToSeq():
      msg.o[].add s
  sonicOut[msg] = true

template notForServer() = warn "Don't use from server."

proc deleteFromSonic*(capts: UriCaptures, col = config.websiteDomain): int =
  ## Delete an article from sonic db
  notForServer()
  let key = join([capts.topic, capts.page, capts.art], "/")
  sonic.flush(conn, col = config.websiteDomain.cptr, buc = defaultBucket,
      obj = key.cptr)

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
  notForServer()
  var total, c, pagenum: int
  let pushLog = await readPushLog()
  if pushLog.len == 0:
    sonic.flush(conn, buc = defaultBucket,
                col = config.websiteDomain.cptr, obj = emptyCStr)
  defer:
    sonic.consolidate(conn)
  for (topic, state) in topicsCache:
    if topic notin pushLog:
      pushLog[topic] = %0
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
      await allFutures(futs)
      pushLog[topic] = %pagenum
      await writePushLog(pushLog)
  info "Indexed search for {config.websiteDomain} with {total} objects."

from chronos/timer import seconds, Duration

proc query*(topic: string, keywords: string, lang: string = SLang.code,
            limit = defaultLimit): Future[seq[string]] {.async.} =
  ## Thread safe sonic query
  if unlikely(keywords.len == 0):
    return
  var msg: SonicMessageTuple
  msg.args.col = config.websiteDomain
  msg.args.topic = topic
  msg.args.keywords = keywords
  msg.args.lang = lang
  msg.args.limit = limit
  msg.kind = query
  msg.o = result.addr
  msg.id = getMonoTime()
  # await querySonic(msg.addr)
  sonicIn.add(msg.addr)
  discard await sonicOut.pop(msg.addr)

# import quirks # required by py DetectLang
proc suggest*(topic, input: string, limit = defaultLimit): Future[seq[
    string]] {.async.} =
  if unlikely(input.len == 0):
    return
  var msg: SonicMessageTuple
  msg.args.col = config.websiteDomain
  msg.args.topic = topic
  msg.args.keywords = input
  msg.kind = sugg
  # var dlang: string
  # withPyLock:
  #   dlang = DetectLang[](input).to(string)
  # msg.args.lang = await toISO3(dlang)
  msg.args.limit = limit
  msg.o = result.addr
  msg.id = getMonoTime()
  # await suggestSonic(msg.addr)
  sonicIn.add(msg.addr)
  discard await sonicOut.pop(msg.addr)

proc connectSonic(reconnect = false) =
  var notConnected: bool
  conn = sonic.sonic_connect(host = host, pass = pass)
  doassert not conn.isnil and sonic.isopen(conn), "Is Sonic running?"

template restartSonic(what: string) {.dirty.} =
  logexc()
  if e is OSError:
    connectSonic(reconnect = true)

proc asyncSonicHandler() {.async, gcsafe.} =
  try:
    var q: SonicMessage
    while true:
      sonicIn.pop(q)
      clearFuts(futs)
      checkNil(q):
        futs.add case q.kind:
          of query: querySonic(move q)
          of sugg: suggestSonic(move q)
  except Exception as e: # If we quit we can catch defects too.
    logexc()
    warn "sonic: sonic handler crashed."

proc sonicHandler() =
  while true:
    waitFor asyncSonicHandler()
    sleep(1000)
    warn "Restarting sonic..."

proc initSonic*() {.gcsafe.} =
  when not defined(release):
    pushLock = create(AsyncLock)
    pushLock[] = newAsyncLock()
  connectSonic()
  setNil(sonicIn):
    newAsyncPColl[SonicMessage]()
  setNil(sonicOut):
    newAsyncTable[SonicMessage, bool]()
  createThread(sonicThread, sonicHandler)

when isMainModule:
  initSonic()
  # waitFor syncTopics(true)
  # waitFor pushAllSonic()
  debug "nice"
  let q = waitFor query("mini", "mini", "hello")
  echo q
  # let qq = waitFor query("mini", "mini", "es")
  # echo qq
  # debug "done"
  # let qq = waitFor suggest("mini", "mini")
  # echo qq
  # push(relpath)
  # discard controlClient.trigger("consolidate")
  # echo suggest("web", "web host")
