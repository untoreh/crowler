import chronos
import chronos/selectors2
import std/importutils

proc clearTD() =
  privateAccess(PDispatcher)
  try:
    getThreadDispatcher().selector.close()
    setThreadDispatcher(nil)
    GC_runOrc()
  except:
    discard

proc registerChronosCleanup*() =
  ## Ensures chronos dispatcher is freed from memory on thread destruction
  onThreadDestruction(clearTD)
