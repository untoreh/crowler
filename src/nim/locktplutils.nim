## This file should be included

import chronos
import locktpl

template sleep() = await sleepAsync(1.milliseconds)

when declared(LockTable):
  proc getWait*[K, V](tbl: LockTable[K, V], k: K): Future[V] {.async.} =
    while true:
      if k in tbl:
        return tbl[k]
      else:
        sleep()

  proc popWait*[K, V](tbl: LockTable[K, V], k: K, v: var V) {.async.} =
    while true:
      if k in tbl:
        tbl.pop(k, v)
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
