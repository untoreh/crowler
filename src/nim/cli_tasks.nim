import chronos
import cligen

const SERVER_MODE* {.booldefine.} = true

import server_tasks
import pyutils, search, lsh, nativehttp, topics, shorturls

proc cliRunTasks() =
  initSonic()
  startLSH()
  initHttp()
  initTopics()
  initZstd()
  waitFor runTasks(@[pub, cleanup, mem], wait=true)

when isMainModule:
  dispatchMulti([cliRunTasks])
