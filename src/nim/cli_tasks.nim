import chronos
import cligen

import server_tasks

proc cliRunTasks() =
  waitFor runTasks(@[pub, cleanup, mem], wait=true)

when isMainModule:
  dispatchMulti([cliRunTasks])
