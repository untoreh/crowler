import nimpy, uri, strformat
import
    cfg,
    types,
    utils,
    quirks,
    articles

type
    TopicState* = tuple[topdir: int, group: PyObject]
    Topics* = LockTable[string, TopicState]
let
    topicsCache*: Topics = initLockTable[string, TopicState]()
    emptyTopic* = (topdir: -1, group: PyObject())

proc lastPageNum*(topic: string): int = ut.get_top_page(topic).to(int)

proc fetch*(t: Topics, k: string): TopicState =
    t.lgetOrPut(k):
        (topdir: lastPageNum(k), group: ut.topic_group(k))

proc getState*(topic: string): (int, int) =
    ## Get the number of the top page, and the number of `done` pages.
    let
        grp = topicsCache.fetch(topic).group
        topdir = max(grp[$topicData.pages].shape[0].to(int)-1, 0)
        numdone = max(len(grp[$topicData.done]) - 1, 0)
    assert topdir == lastPageNum(topic)
    return (topdir, numdone)

proc syncTopics*() {.gcsafe.} =
    # NOTE: the [0] is required because quirky zarray `getitem`
    try:
        let
            pytopics = initPySequence[string](ut.load_topics()[0])
            n_topics = pytopics.len

        if n_topics > topicsCache.len:
            for topic in pytopics.slice(topicsCache.len, pytopics.len):
                let
                    tp = topic[0].to(string)
                    tg = ut.topic_group(tp)
                    td = tp.getState[0]
                # debug "synctopics: adding topic {tp} to global"
                # topicsCache[tp] = (topdir: td, group: tg)
    except Exception as e:
        debug "could not sync topics {getCurrentExceptionMsg()}"

import quirks # PySequence requires quirks
export nimpy
proc loadTopics*(): PySequence[string] = initPySequence[string](ut.load_topics()[0])
proc loadTopics*(n: int): PySequence[string] = initPySequence[string](loadTopics().slice(0, n))

proc topicDesc*(topic: string): string = ut.get_topic_desc(topic).to(string)
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)

proc pageSize*(topic: string, pagenum: int): int =
    let py = ut.get_page_size(topic, pagenum)
    if pyisnone(py):
        error fmt"Page number: {pagenum} not found for topic: {topic} ."
        return 0
    py[0].to(int)


when isMainModule:
    # synctopics()
    echo "vps".getState[0]
    # echo typeof(topicsCache.fetch("vps"))
