import nimpy, uri, strformat, times, sugar, os, chronos
import
  cfg,
  types,
  utils,
  quirks,
  pyutils,
  locktpl

lockedStore(OrderedTable)
type
  TopicState* = tuple[topdir: int, group: ptr PyObject]
  Topics* = LockOrderedTable[string, TopicState]

pygil.globalAcquire()
let
  topicsCache*: Topics = initLockOrderedTable[string, TopicState]()
  pyTopicsMod = create(PyObject)
let emptyTopic* = (topdir: -1, group: create(PyObject))
emptyTopic.group[] = PyObject()
pyTopicsMod[] = if os.getEnv("NEW_TOPICS_ENABLED", "") != "":
                      # discard relPyImport("proxies_pb") # required by topics
                      # discard relPyImport("translator") # required by topics
                      # discard relPyImport("adwords_keywords") # required by topics
                      pyImport("topics")
                  else: PyNone
pygil.release()

template lastPageNumImpl(topic: string): untyped =
  # assert not site[].isnil
  let tpg = site[].get_top_page(topic)
  # assert not tpg.isnil
  tpg.to(int)

proc lastPageNum*(topic: string): Future[int] {.async.} =
  withPyLock:
    result = lastPageNumImpl(topic)

# quirks imported toplevel
import strutils
export nimpy
proc loadTopicsIndex*(): PyObject =
  try:
    syncPyLock:
      result = site[].load_topics()[0]
      checkNil(result)
      checkTrue not pyisnone(result), "topics: could not load topics."
  except:
    let m = getCurrentExceptionMsg()
    if "shape is None" in m:
      sdebug "Couldn't load topics, is data dir present?"

proc isEmptyTopic*(topic: string): Future[bool] {.async.} =
  withPyLock:
    let isEmptyTopicPy {.global.} = site[].getattr("is_empty")
    result = isEmptyTopicPy(topic).to(bool)

type TopicTuple* = (string, string, int)
proc loadTopics*(force = false): Future[PySequence[TopicTuple]] {.async.} =
  withPyLock:
    return initPySequence[TopicTuple](site[].load_topics(force)[0])

proc loadTopics*(n: int; ): Future[seq[PyObject]] {.async.} =
  let tp = await loadTopics()
  var clt, nTopics, max: int
  withPyLock:
    nTopics = tp.len
  template addTopic() =
    var topic: string
    var t: PyObject
    withPyLock:
      t = tp[c]
      topic = t[0].to(string)
    if not (await topic.isEmptyTopic()):
      clt += 1
      result.add t
    if clt >= max: # reached the requested number of topics
      break
  if n >= 0:
    var c = 0
    max = n
    for c in countUp(0, nTopics - 1):
      addTopic()
  else:
    max = abs(n)
    for c in countDown(nTopics - 1, 0):
      addTopic()

proc topicDesc*(topic: string): Future[string] {.async.} =
  withPyLock:
    return site[].get_topic_desc(topic).to(string)
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)


proc pageSize*(topic: string, pagenum: int): Future[int] {.async.} =
  withPyLock:
    let py = site[].get_page_size(topic, pagenum)
    if pyisnone(py):
      error fmt"Page number: {pagenum} not found for topic: {topic} ."
      return 0
    result = py[0].to(int)

var topicIdx = 0
let pyTopics = create(PyObject)
pyTopics[] = loadTopicsIndex()

proc nextTopic*(): Future[string] {.async.} =
  checkNil(pyTopics[], "topics: index can't be nil."):
    withPyLock:
      if len(pyTopics[]) <= topicIdx:
        debug "pubtask: resetting topics idx ({len(pyTopics[])})"
        topicIdx = 0
      result = pyTopics[][topicIdx][0].to(string)
      topicIdx += 1

proc topicPubdate*(idx: int): Future[Time] {.async.} =
  withPyLock:
    return site[].get_topic_pubDate(idx).to(int).fromUnix
proc topicPubdate*(): Future[Time] {.async.} = return await topicPubdate(max(0,
    topicIdx - 1))
proc updateTopicPubdate*(idx: int) {.async.} =
  withPyLock:
    discard site[].set_topic_pubDate(idx)
proc updateTopicPubdate*() {.async.} = await updateTopicPubdate(max(0,
    topicIdx - 1))

proc getTopicGroup*(topic: string): Future[ptr PyObject] {.async.} =
  withPyLock:
    result = create(PyObject)
    result[] = site[].topic_group(topic)

proc topicDonePages*(topic: string): Future[PyObject] {.async.} =
  withPyLock:
    return site[].topic_group(topic)[$topicData.done]

proc topicPages*(topic: string): Future[PyObject] {.async.} =
  withPyLock:
    return site[].topic_group(topic)[$topicData.pages]

proc topicPage*(topic: string, page = -1): Future[PyObject] {.async.} =
  withPyLock:
    let pagenum = if page < 0: lastPageNumImpl(topic) else: page
    result = site[].topic_group(topic)[$topicData.done][pagenum]

proc topicArticles*(topic: string): Future[PyObject] {.async.} =
  withPyLock:
    return site[].topic_group(topic)[$topicData.articles]

proc publishedArticles*[V](topic: string, attr: string = ""): Future[seq[(
    PyObject, V)]] {.async.} =
  var
    pydone: PyObject
    page: PyObject
    art: PyObject
    nPages: int
    nArts: int
    v: V
  withPyLock:
    pydone = site[].topic_group(topic)[$topicData.done]
    nPages = len(pydone)
  let getArticleAttr = if attr != "": (art: PyObject) => pyget[V](art, attr,
      default(V))
                        else: (art: PyObject) => ""

  for d in 0..<nPages:
    withPyLock:
      page = pydone[d]
      checkNil(page):
        nArts = len(page)
    for a in 0..<nArts:
      withPyLock:
        art = page[a]
        if not pyisnone(art):
          v = getArticleAttr(art)
        else:
          v = default(V)
      result.add (art, v)

proc fetch*(t: Topics, k: string): Future[TopicState] {.async.} =
  return t.lgetOrPut(k):
    (topdir: await lastPageNum(k), group: await getTopicGroup(k))

proc getState*(topic: string): Future[(int, int)] {.async.} =
  ## Get the number of the top page, and the number of `done` pages.
  checkTrue topic != "", "gs: topic should not be empty"
  let cache = await topicsCache.fetch(topic)
  var grp: PyObject
  withPyLock:
    grp = cache.group[]
  doassert not grp.isnil, "gs: group is nil"
  var topdir, numdone: int
  const pgK = $topicData.pages
  const doneK = $topicData.done
  withPyLock:
    doassert not grp[pgK].isnil
    if not pyisnone(grp[pgK].shape):
      topdir = max(grp[pgK].shape[0].to(int)-1, 0)
      numdone = max(len(grp[doneK]) - 1, 0)
    else:
      topdir = -1
  assert topdir != -1 and topdir == (await lastPageNum(topic))
  return (topdir, numdone)

proc hasArticles*(topic: string): Future[bool] {.async.} =
  let cache = await topicsCache.fetch(topic)
  withPyLock:
    var grp {.inject.} = cache.group[]
    return grp[$topicData.done].len > 0 and grp[$topicData.done][0].len > 0

var topicsCount {.threadvar.}: int # Used to check if topics are in sync, but it is not perfect (in case topics deletions happen)
topicsCount = -1
proc syncTopics*(force = false) {.gcsafe, async.} =
  # NOTE: the [0] is required because quirky zarray `getitem`
  withPyLock:
    assert not site[].isnil
    let tc = site[].get_topic_count().to(int)
    if topicsCount == tc:
      return
    else:
      topicsCount = tc
  try:
    var
      pytopics = await loadTopics(force)
      nTopics: int
    withPyLock:
      nTopics = pytopics.len
      if nTopics == 0 and (not pyisnone(pyTopicsMod[])):
        discard pyTopicsMod[].new_topic()
        pygil.release()
        pytopics = await loadTopics()
        await pygil.acquire()
        nTopics = pytopics.len
        assert nTopics > 0

    if nTopics > topicsCache.len:
      {.locks: [pyGilLock].}:
        await pygil.acquire()
        for topic in pytopics.slice(topicsCache.len, pytopics.len):
          let tp = topic[0].to(string)
          pygil.release()
          logall "synctopics: adding topic {tp} to global"
          # topicsCache[tp] = (topdir: td, group: tg)
          discard topicsCache.fetch(tp)
          await pygil.acquire()
        pygil.release()
  except CatchableError as e:
    let e = getCurrentException()[]
    debug "could not sync topics {e}"

when isMainModule:
  initPy()
  discard synctopics()
  # let v = waitFor topicPage("mini")
  # syncPyLock:
    # echo v[0]
  # echo typeof(topicsCache.fetch("vps"))
