when isMainModule:
  initPy()
  initTopics()
  let topics = waitFor loadTopics()
  syncPyLock:
    echo topics[0].toTopicTuple
  echo waitFor nextTopic()
