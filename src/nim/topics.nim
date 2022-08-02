import nimpy, uri, strformat, times, sugar, os, chronos
import
    cfg,
    types,
    utils,
    quirks,
    pyutils

type
    TopicState* = tuple[topdir: int, group: ptr PyObject]
    Topics* = LockTable[string, TopicState]

pygil.globalAcquire()
let
    topicsCache*: Topics = initLockTable[string, TopicState]()
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

proc lastPageNum*(topic: string): Future[int] {.async.} =
    withPyLock:
        # assert not site[].isnil
        let tpg = site[].get_top_page(topic)
        # assert not tpg.isnil
        return tpg.to(int)

import quirks # PySequence requires quirks
import strutils
export nimpy
proc loadTopicsIndex*(): PyObject =
    try:
        syncPyLock:
            result = site[].load_topics()[0]
            doassert not result.isnil
    except:
        let m = getCurrentExceptionMsg()
        if "shape is None" in m:
            qdebug "Couldn't load topics, is data dir present?"

type TopicTuple* = (string, string, int)
proc loadTopics*(force=false): Future[PySequence[TopicTuple]] {.async.} =
    withPyLock:
        return initPySequence[TopicTuple](site[].load_topics(force)[0])

proc loadTopics*(n: int): Future[PySequence[TopicTuple]] {.async.} =
    let tp  = await loadTopics()
    withPyLock:
        return initPySequence[TopicTuple](tp.slice(0, n))

proc topicDesc*(topic: string): Future[string] {.async.} =
    withPyLock:
        return site[].get_topic_desc(topic).to(string)
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)

proc isEmptyTopic*(topic: string): Future[bool] {.async.} =
    withPyLock:
        assert not site[].isnil, "site should not be nil"
        let empty_f = site[].getattr("is_empty")
        assert not empty_f.isnil, "empty_f should not be nil"
        let empty_topic = empty_f(topic)
        assert not empty_topic.isnil, "topic check should not be nil"
        result = empty_topic.to(bool)

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
    if pyTopics.isnil or pyTopics[].isnil:
        pyTopics[] = loadTopicsIndex()
    var pycheck: bool
    withPyLock:
        pycheck = pyisnone(pyTopics[])
    if pycheck:
        pyTopics[] = loadTopicsIndex()
    withPyLock:
        pycheck = pyTopics.isnil or pyisnone(pyTopics[])
    if pycheck:
        raise newException(Exception, "topics: could not load topics.")
    withPyLock:
        if len(pyTopics[]) <= topicIdx:
            debug "pubtask: resetting topics idx ({len(pyTopics[])})"
            topicIdx = 0
        return pyTopics[][topicIdx][0].to(string)
    topicIdx += 1

proc topicPubdate*(idx: int): Future[Time] {.async.} =
    withPyLock:
        return site[].get_topic_pubDate(idx).to(int).fromUnix
proc topicPubdate*(): Future[Time] {.async.} = return await topicPubdate(max(0, topicIdx - 1))
proc updateTopicPubdate*(idx: int) {.async.} =
    withPyLock:
        discard site[].set_topic_pubDate(idx)
proc updateTopicPubdate*() {.async.} =  await updateTopicPubdate(max(0, topicIdx - 1))

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

proc topicArticles*(topic: string): Future[PyObject] {.async.} =
    withPyLock:
        return site[].topic_group(topic)[$topicData.articles]

proc publishedArticles*[V](topic: string, attr: string = ""): Future[seq[(PyObject, V)]] {.async.} =
    var
        pydone: PyObject
        page: PyObject
        art:  PyObject
        n_pages: int
        n_arts : int
        v: V
    withPyLock:
        pydone = site[].topic_group(topic)[$topicData.done]
        n_pages = len(pydone)
    let getArticleAttr = if attr != "": (art: PyObject) => pyget[V](art, attr, default(V))
                        else: (art: PyObject) => ""
    for d in 0..<n_pages:
        withPyLock:
            page = pydone[d]
            n_arts = len(page)
        for a  in 0..<n_arts:
            withPyLock:
                assert not page.isnil
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
    doassert topic != "", "gs: topic should not be empty"
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

var topicsCount {.threadvar.}: int # Used to check if topics are in sync, but it is not perfect (in case topics deletions happen)
topicsCount = -1
proc syncTopics*(force=false) {.gcsafe, async.} =
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
            n_topics: int
        withPyLock:
            n_topics = pytopics.len
            if n_topics == 0 and (not pyisnone(pyTopicsMod[])):
                discard pyTopicsMod[].new_topic()
                pygil.release()
                pytopics = await loadTopics()
                await pygil.acquire()
                n_topics = pytopics.len
                assert n_topics > 0

        if n_topics > topicsCache.len:
            {.locks: [pyGilLock]}:
                await pygil.acquire()
                for topic in pytopics.slice(topicsCache.len, pytopics.len):
                    let tp = topic[0].to(string)
                    pygil.release()
                    logall "synctopics: adding topic {tp} to global"
                    # topicsCache[tp] = (topdir: td, group: tg)
                    discard topicsCache.fetch(tp)
                    await pygil.acquire()
                pygil.release()
    except Exception as e:
      let e = getCurrentException()[]
      debug "could not sync topics {e}"

when isMainModule:
    synctopics()
    echo inHours(getTime() - topicPubDate())
    # echo typeof(topicsCache.fetch("vps"))
