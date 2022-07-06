import nimpy, uri, strformat, times, sugar, os
import
    cfg,
    types,
    utils,
    quirks,
    pyutils

type
    TopicState* = tuple[topdir: int, group: PyObject]
    Topics* = LockTable[string, TopicState]
let
    topicsCache*: Topics = initLockTable[string, TopicState]()
    emptyTopic* = (topdir: -1, group: PyObject())
    pyTopicsMod = if os.getEnv("NEW_TOPICS_ENABLED", "") != "":
                      discard relPyImport("proxies_pb") # required by topics
                      discard relPyImport("translator") # required by topics
                      discard relPyImport("adwords_keywords") # required by topics
                      relPyImport("topics")
                  else: PyNone

proc lastPageNum*(topic: string): int =
    withPyLock:
        assert not site.isnil
        let tpg = site.get_top_page(topic)
        assert not tpg.isnil
        return tpg.to(int)

import quirks # PySequence requires quirks
import strutils
export nimpy
proc loadTopicsIndex*(): PyObject =
    try:
        withPyLock:
            result = site.load_topics()[0]
            doassert not result.isnil
    except:
        let m = getCurrentExceptionMsg()
        if "shape is None" in m:
            qdebug "Couldn't load topics, is data dir present?"

type TopicTuple* = (string, string, int)
proc loadTopics*(force=false): PySequence[TopicTuple] =
    withPyLock:
        return initPySequence[TopicTuple](site.load_topics(force)[0])

proc loadTopics*(n: int): PySequence[TopicTuple] =
    let tp  = loadTopics()
    withPyLock:
        return initPySequence[TopicTuple](tp.slice(0, n))

proc topicDesc*(topic: string): string =
    withPyLock:
        return site.get_topic_desc(topic).to(string)
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)

proc isEmptyTopic*(topic: string): bool =
    withPyLock:
        assert not site.isnil, "site should not be nil"
        let empty_f = site.getattr("is_empty")
        assert not empty_f.isnil, "empty_f should not be nil"
        let empty_topic = empty_f(topic)
        assert not empty_topic.isnil, "topic check should not be nil"
        result = empty_topic.to(bool)

proc pageSize*(topic: string, pagenum: int): int =
    withPyLock:
        let py = site.get_page_size(topic, pagenum)
        if pyisnone(py):
            error fmt"Page number: {pagenum} not found for topic: {topic} ."
            return 0
        result = py[0].to(int)

var topicIdx = 0
let pyTopics = create(PyObject)
pyTopics[] = loadTopicsIndex()

proc nextTopic*(): string =
    if pyTopics.isnil or pyTopics[].isnil:
        pyTopics[] = loadTopicsIndex()
    if withPyLock(pyisnone(pyTopics[])):
        pyTopics[] = loadTopicsIndex()
    if pyTopics.isnil or withPyLock(pyisnone(pyTopics[])):
        raise newException(Exception, "topics: could not load topics.")
    withPyLock:
        if len(pyTopics[]) <= topicIdx:
            debug "pubtask: resetting topics idx ({len(pyTopics[])})"
            topicIdx = 0
        result = pyTopics[][topicIdx][0].to(string)
    topicIdx += 1

proc topicPubdate*(idx: int): Time =
    withPyLock:
        return site.get_topic_pubDate(idx).to(int).fromUnix
proc topicPubdate*(): Time = topicPubdate(max(0, topicIdx - 1))
proc updateTopicPubdate*(idx: int) =
    withPyLock:
        discard site.set_topic_pubDate(idx)
proc updateTopicPubdate*() =  updateTopicPubdate(max(0, topicIdx - 1))

proc getTopicGroup*(topic: string): PyObject =
    withPyLock:
        return site.topic_group(topic)

proc topicDonePages*(topic: string): PyObject =
    withPyLock:
        return site.topic_group(topic)[$topicData.done]

proc topicPages*(topic: string): PyObject =
    withPyLock:
        return site.topic_group(topic)[$topicData.pages]

proc topicArticles*(topic: string): PyObject =
    withPyLock:
        return site.topic_group(topic)[$topicData.articles]

iterator publishedArticles*[V](topic: string, attr: string = ""): (PyObject, V) =
    var
        pydone: PyObject
        page: PyObject
        art:  PyObject
        n_pages: int
        n_arts : int
        v: V
    withPyLock:
        pydone = site.topic_group(topic)[$topicData.done]
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
            yield (art, v)


proc fetch*(t: Topics, k: string): TopicState =
    t.lgetOrPut(k):
        (topdir: lastPageNum(k), group: getTopicGroup(k))

proc getState*(topic: string): (int, int) =
    ## Get the number of the top page, and the number of `done` pages.
    doassert topic != "", "gs: topic should not be empty"
    let grp = topicsCache.fetch(topic).group
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
    assert topdir != -1 and topdir == lastPageNum(topic)
    return (topdir, numdone)

var topicsCount {.threadvar.}: int # Used to check if topics are in sync, but it is not perfect (in case topics deletions happen)
topicsCount = -1
proc syncTopics*(force=false) {.gcsafe} =
    # NOTE: the [0] is required because quirky zarray `getitem`
    withPyLock:
        assert not site.isnil
        let tc = site.get_topic_count().to(int)
        if topicsCount == tc:
            return
        else:
            topicsCount = tc
    try:
        var
            pytopics = loadTopics(force)
            n_topics: int
        withPyLock:
            n_topics = pytopics.len
            if n_topics == 0 and (not pyisnone(pyTopicsMod)):
                discard pyTopicsMod.new_topic()
                pytopics = loadTopics()
                n_topics = pytopics.len
                assert n_topics > 0

        if n_topics > topicsCache.len:
            {.locks: [pyLock]}:
                pyLock.acquire()
                for topic in pytopics.slice(topicsCache.len, pytopics.len):
                    let tp = topic[0].to(string)
                    pyLock.release()
                    debug "synctopics: adding topic {tp} to global"
                    # topicsCache[tp] = (topdir: td, group: tg)
                    discard topicsCache.fetch(tp)
                    pyLock.acquire()
                pyLock.release()
    except Exception as e:
        debug "could not sync topics {getCurrentExceptionMsg()} {getStackTrace()}"

when isMainModule:
    synctopics()
    echo inHours(getTime() - topicPubDate())
    # echo typeof(topicsCache.fetch("vps"))
