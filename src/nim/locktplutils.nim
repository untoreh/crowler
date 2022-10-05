## This file should be included

import chronos
import locktpl

template sleep() = await sleepAsync(1.milliseconds)

# NOTE: When using locktables and locklists for producer/consumer, ensure that the keys are unique.
# (e.g. instead of `k = 123` do `k = (getMonoTime(), 123)` )
when declared(LockTable):
  proc getWait*[K, V](tbl: LockTable[K, V], k: K): Future[V] {.async.} =
    while true:
      if k in tbl:
        return tbl[k]
      else:
        sleep()

  proc popWait*[K, V](tbl: LockTable[K, V], k: K): Future[V] {.async.} =
    while true:
      if k in tbl:
        doAssert tbl.pop(k, result)
        break
      else:
        sleep()

when declared(LockDeque):
  proc popFirstWait*[T](q: LockDeque[T]): Future[T] {.async.} =
    while true:
      if q.len > 0:
        return q.popFirst()
      else:
        sleep()
