when isMainModule:
  import os
  import chronos_patches
  # let t = newAsyncTable[int, bool]()
  let t = newAsyncPColl[bool]()
  # let t = newThreadLock()
  var t1: Thread[void]
  var t2: Thread[void]
  template test() =
    proc dopop() =
      registerChronosCleanup()
      echo "pop waiting..."
      # echo waitFor t.pop(0)
      echo waitFor t.pop()

      # waitFor t.acquire()
      # t.release()
      echo "pop!"
    proc doput() =
      registerChronosCleanup()
      echo "put waiting..."
      # waitFor t.acquire()
      # t.release()
      # waitFor sleepAsync(10.milliseconds)
      # waitFor t.put(0, false)
      t.add true
      echo "put!"
    createThread(t1, dopop)
    createThread(t2, doput)
    joinThreads(t1, t2)
  proc run() =
    for _ in 0..100:
      test()
  for i in 0..100:
    echo i
    run()
  echo "finished"
