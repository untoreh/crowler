import nimpy, uri, strformat, times
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

proc lastPageNum*(topic: string): int =
    withPyLock:
        assert not ut.get_top_page(topic).isnil
        return ut.get_top_page(topic).to(int)

import quirks # PySequence requires quirks
import strutils
export nimpy
proc loadTopicsIndex*(): PyObject =
    try:
        withPyLock:
            return ut.load_topics()[0]
    except:
        let m = getCurrentExceptionMsg()
        if "shape is None" in m:
            qdebug "Couldn't load topics, is data dir present?"

type TopicTuple* = (string, string, int)
proc loadTopics*(): PySequence[TopicTuple] =
    withPyLock:
        return initPySequence[TopicTuple](ut.load_topics()[0])

proc loadTopics*(n: int): PySequence[TopicTuple] =
    let tp  = loadTopics()
    withPyLock:
        return initPySequence[TopicTuple](tp.slice(0, n))

proc topicDesc*(topic: string): string =
    withPyLock:
        return ut.get_topic_desc(topic).to(string)
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)

proc pageSize*(topic: string, pagenum: int): int =
    withPyLock:
        let py = ut.get_page_size(topic, pagenum)
        if pyisnone(py):
            error fmt"Page number: {pagenum} not found for topic: {topic} ."
            return 0
        result = py[0].to(int)

var topicIdx = 0
let pyTopics = create(PyObject)
pyTopics[] = loadTopicsIndex()

proc nextTopic*(): string =
    if pyTopics.isnil:
        pyTopics[] = loadTopicsIndex()
    withPyLock:
        if len(pyTopics[]) <= topicIdx:
            debug "pubtask: resetting topics idx ({len(pyTopics[])})"
            topicIdx = 0
        result = pyTopics[][topicIdx][0].to(string)
    topicIdx += 1

proc topicPubdate*(idx: int): Time =
    withPyLock:
        return ut.get_topic_pubDate(idx).to(int).fromUnix
proc topicPubdate*(): Time = topicPubdate(max(0, topicIdx - 1))
proc updateTopicPubdate*(idx: int) =
    withPyLock:
        discard ut.set_topic_pubDate(idx)
proc updateTopicPubdate*() =  updateTopicPubdate(max(0, topicIdx - 1))

proc topicGroup*(topic: string): PyObject =
    withPyLock:
        return ut.topic_group(topic)

proc topicDonePages*(topic: string): PyObject =
    withPyLock:
        return ut.topic_group(topic)[$topicData.done]

proc topicPages*(topic: string): PyObject =
    withPyLock:
        return ut.topic_group(topic)[$topicData.pages]

proc topicArticles*(topic: string): PyObject =
    withPyLock:
        return ut.topic_group(topic)[$topicData.articles]

proc fetch*(t: Topics, k: string): TopicState =
    t.lgetOrPut(k):
        (topdir: lastPageNum(k), group: topicGroup(k))

proc getState*(topic: string): (int, int) =
    ## Get the number of the top page, and the number of `done` pages.
    let grp = topicsCache.fetch(topic).group
    doassert not grp.isnil
    var topdir, numdone: int
    withPyLock:
        doassert not grp[$topicData.pages].isnil
        doassert not grp[$topicData.pages].shape.isnil
        topdir = max(grp[$topicData.pages].shape[0].to(int)-1, 0)
        numdone = max(len(grp[$topicData.done]) - 1, 0)
    assert topdir == lastPageNum(topic)
    return (topdir, numdone)

proc syncTopics*() {.gcsafe} =
    # NOTE: the [0] is required because quirky zarray `getitem`
    withPyLock:
        assert not ut.isnil
    try:
        let pytopics = loadTopics()
        var n_topics: int
        withPyLock:
            n_topics = pytopics.len

        if n_topics > topicsCache.len:
            {.locks: [pyLock]}:
                pyLock.acquire()
                for topic in pytopics.slice(topicsCache.len, pytopics.len):
                    let
                        tp = topic[0].to(string)
                        tg = ut.topic_group(tp)
                    pyLock.release()
                    let td = tp.getState[0]
                    debug "synctopics: adding topic {tp} to global"
                    topicsCache[tp] = (topdir: td, group: tg)
                    pyLock.acquire()
                pyLock.release()
    except Exception as e:
        debug "could not sync topics {getCurrentExceptionMsg()}"

when isMainModule:
    synctopics()
    echo inHours(getTime() - topicPubDate())
    # echo typeof(topicsCache.fetch("vps"))
