import chronos

import "../src/nim/cfg"
import "../src/nim/topics"
import "../src/nim/pyutils"

when isMainModule:
  initConfig()
  initPy()
  initTopics()
  let tops = waitFor loadTopics()
  syncPyLock:
    discard
    # echo topics.toTopicTuple(tops[0])
  for (k, v) in topicsCache:
    discard
    # echo k
    # echo v.topdir
    # echo v.name
  echo waitFor nextTopic()
