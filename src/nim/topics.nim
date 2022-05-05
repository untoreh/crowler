import nimpy, uri
import
    cfg,
    types,
    utils,
    quirks
type
    TopicState* = tuple[topdir: int, group: PyObject]
    Topics* = ptr LockTable[string, TopicState]
let
    topicsCache* = initLockTable[string, TopicState]()
    emptyTopic* = (topdir: -1, group: PyObject())

proc len*(t: Topics): int = t[].len
proc `[]=`*(t: Topics, k, v: auto) = t[][k] = v
proc `[]`*(t: Topics, k: string): TopicState = t[][k]
proc contains*(t: Topics, k: string): bool = k in t[]
proc get*(t: Topics, k: string, d: TopicState): TopicState = t[].get(k, d)

proc getState*(topic: string): (int, int) =
    ## Get the number of the top page, and the number of `done` pages.
    let
        grp = ut.topic_group(topic)
        topdir = max(grp[$topicData.pages].shape[0].to(int)-1, 0)
        numdone = max(len(grp[$topicData.done]) - 1, 0)
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
                    tp = topic.to(string)
                    tg = ut.topic_group(tp)
                    td = tp.getState[0]
                debug "synctopics: adding topic {tp} to global"
                topicsCache[tp] = (topdir: td, group: tg)
    except Exception as e:
        debug "could not sync topics {getCurrentExceptionMsg()}"

import quirks # PySequence requires quirks
export nimpy
proc loadTopics*(): PySequence[string] = initPySequence[string](ut.load_topics()[0])
proc loadTopics*(n: int): PySequence[string] = initPySequence[string](loadTopics().slice(0, n))

proc topicDesc*(topic: string): string = ""
proc topicUrl*(topic: string, lang: string): string = $(WEBSITE_URL / lang / topic)
