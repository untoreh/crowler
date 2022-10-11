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
        var res: V
        doAssert tbl.pop(k, res)
        return res
      else:
        sleep()

when declared(LockDeque):
  proc popFirstWait*[T](q: LockDeque[T]): Future[T] {.async.} =
    while true:
      if q.len > 0:
        return q.popFirst()
      else:
        sleep()

import sharedqueue
import chronos/asyncloop
proc popFirstWait*[T](q: PColl[T]): Future[T] {.async.} =
  if q.len > 0:
    doassert q.pop(result)
  else:
    result = newFuture[T]("Pcoll.popFirstWait")

type
  AsyncPCollObj[T] = object
    lock: Lock
    waiters: PColl[ptr Future[T]]
    pcoll: Pcoll[T]
  AsyncPColl*[T] = ptr AsyncPCollObj[T]

proc newAsyncPColl*[T](): AsyncPColl[T] =
  result = create(AsyncPCollObj[T])
  initLock(result.lock)
  result.pcoll = newColl[T]()
  result.waiters = newColl[ptr Future[T]]()
  assert not result.waiters.isnil

proc add*[T](apc: AsyncPColl[T], v: T) =
  withLock(apc.lock):

    if apc.waiters.len > 0:
      apc.waiters[0][].complete(v)
      apc.waiters.delete(0)
    else:
      apc.pcoll.add v

proc newFuturePtr[T](name: static string): ptr Future[T] =
  let fut = create(Future[T])
  fut[] = newFuture[T](name)
  proc cb(f: pointer) =
    if not fut.isnil:
      reset(fut[])
      dealloc(fut)
  addCallBack(fut[], cb)
  fut

proc pop*[T](apc: AsyncPColl[T]): Future[T] =
  let fut = newFuturePtr[T]("AsyncPColl.pop")
  withLock(apc.lock):
    var v: T
    if apc.pcoll.pop(v):
      fut[].complete(v)
      return fut[]
    else:
      apc.waiters.add fut
  fut[]

proc add*[T](apc: AsyncPColl[T]): Future[T] {.async.} =
  withLock(apc.lock):
    var clear: seq[int]
    for i in 0..<apc.waiters.len:
      if apc.waiters[i].finished:
        clear.add i
    apc.waiters.pop(clear)
  result = await apc.popImpl()
  # withLock(apc.lock):
  #   apc.waiters[0].delete()

proc delete*[T](apc: AsyncPColl[T]) =
  apc.waiters.delete()
  apc.pcoll.delete()
  deinitLock(apc.lock)
  dealloc(apc)

type
  ThreadLockObj = object
    lock: Lock
    waiters: PColl[ptr Future[void]]
  ThreadLock = ptr ThreadLockObj

proc newThreadLock*(): ThreadLock =
  result = create(ThreadLockObj)
  initLock(result.lock)
  result.waiters = newColl[ptr Future[void]]()

proc acquire*(t: ThreadLock): Future[void] {.async.} =
  while not t.lock.tryacquire():
    let fut = newFuturePtr[void]("ThreadLock.acquire")
    t.waiters.add fut
    await fut[]

proc release*(t: ThreadLock) =
  if unlikely(t.lock.tryAcquire):
    t.lock.release
    raise newException(ValueError, "ThreadLock was unlocked.")

  if t.waiters.len > 0:
    t.waiters[0][].complete()
    t.waiters.delete(0)

  t.lock.release

template withLock*(l: ThreadLock, code): untyped =
  try:
    await l.acquire()
    code
  finally:
    l.release()

import tables
type
  AsyncTableObj[K, V] = object
    lock: ThreadLock
    waiters: ptr Table[K, ptr seq[ptr Future[V]]]
    table: ptr Table[K, V]
  AsyncTable*[K, V] = ptr AsyncTableObj[K, V]

proc newAsyncTable*[K, V](): AsyncTable[K, V] =
  result = create(AsyncTableObj[K, V])
  result.lock = newThreadLock()
  result.table = create(Table[K, V])
  result.table[] = initTable[K, V]()
  result.waiters = create(Table[K, ptr seq[ptr Future[V]]])
  result.waiters[] = initTable[K, ptr seq[ptr Future[V]]]()

proc pop*[K, V](t: AsyncTable[K, V], k: K): Future[V] {.async.} =
  let fut = newFuturePtr[V]("AsyncTable.getWait")
  withLock(t.lock):
    if k in t.table[]:
      var v: V
      doassert t.table[].pop(k, v)
      fut[].complete(v)
    else:
      if k notin t.waiters[]:
        t.waiters[][k] = create(seq[ptr Future[V]])
      t.waiters[][k][].add fut
  result = await fut[]

proc put*[K, V](t: AsyncTable[K, V], k: K, v: V) {.async.} =
  withLock(t.lock):
    if k in t.waiters[]:
      var ws: ptr seq[ptr Future[V]]
      doassert t.waiters[].pop(k, ws)
      defer: dealloc(ws)
      while ws[].len > 0:
        let w = ws[].pop()
        if not w.isnil:
          w[].complete(v)
    else:
      t.table[][k] = v

template `[]=`*[K, V](t: AsyncTable[K, V], k: K, v: V) =
  await t.put(k, v)

# when isMainModule:
#   import os
#   let t = newAsyncTable[int, bool]()
#   let fut = t.pop(0)
#   waitFor sleepAsync(3.seconds)
#   waitfor t.put(0, false)
#   echo waitFor fut
