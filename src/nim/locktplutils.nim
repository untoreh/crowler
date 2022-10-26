## This file should be included

import chronos
import locktpl

template sleep() = await sleepAsync(10.milliseconds)

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
      var w: ptr Future[T]
      doassert apc.waiters.pop(w)
      w[].complete(v)
    else:
      apc.pcoll.add v

proc pop*[T](apc: AsyncPColl[T]): Future[T] {.async.} =
  let fut = create(Future[T])
  defer:
    if not fut.isnil:
      reset(fut[])
      dealloc(fut)
  fut[] = newFuture[T]("AsyncPColl.pop")
  withLock(apc.lock):
    var v: T
    if apc.pcoll.pop(v):
      fut[].complete(v)
    else:
      apc.waiters.add fut
  while not fut[].finished():
    sleep()
  return fut[].read()

proc delete*[T](apc: AsyncPColl[T]) =
  apc.waiters.delete()
  apc.pcoll.delete()
  deinitLock(apc.lock)
  dealloc(apc)

type
  ThreadLockObj = object
    lock: Lock
  ThreadLock = ptr ThreadLockObj

proc newThreadLock*(): ThreadLock =
  result = create(ThreadLockObj)
  initLock(result.lock)

proc acquire*(t: ThreadLock)  {.async.} =
  while not t.lock.tryacquire():
    sleep()

proc release*(t: ThreadLock) =
  if unlikely(t.lock.tryAcquire):
    t.lock.release
    raise newException(ValueError, "ThreadLock was unlocked.")
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
    waiters: Table[K, seq[pointer]] # pointer future
    table: Table[K, V]
  AsyncTable*[K, V] = ptr AsyncTableObj[K, V]

proc newAsyncTable*[K, V](): AsyncTable[K, V] =
  result = create(AsyncTableObj[K, V])
  result.lock = newThreadLock()
  result.table = initTable[K, V]()
  result.waiters = initTable[K, seq[pointer]]()

proc pop*[K, V](t: AsyncTable[K, V], k: K): Future[V] {.async.} =
  var fut = newFuture[V]("AsyncTable.getWait")
  withLock(t.lock):
    if k in t.table:
      var v: V
      doassert t.table.pop(k, v)
      reset(fut)
      assert fut.isnil
      return v
    else:
      if k notin t.waiters:
        t.waiters[k] = newSeq[pointer]()
      t.waiters[k].add fut.addr
  while not fut.finished:
    sleep()
  if fut.completed:
    return fut.read()
  else:
    raise fut.readError()

proc put*[K, V](t: AsyncTable[K, V], k: K, v: V) {.async.} =
  withLock(t.lock):
    if k in t.waiters:
      var ws: seq[pointer]
      doassert t.waiters.pop(k, ws)
      # defer: dealloc(ws)
      while ws.len > 0:
        let w = ws.pop()
        if not w.isnil:
          let f = cast[ptr Future[V]](w)
          if not f[].finished:
            f[].complete(v)
    else:
      t.table[k] = v

template `[]=`*[K, V](t: AsyncTable[K, V], k: K, v: V) =
  await t.put(k, v)

# when isMainModule:
#   import os
#   import chronos_patches
#   # let t = newAsyncTable[int, bool]()
#   let t = newAsyncPColl[bool]()
#   # let t = newThreadLock()
#   var t1: Thread[void]
#   var t2: Thread[void]
#   template test() =
#     proc dopop() =
#       registerChronosCleanup()
#       echo "pop waiting..."
#       # echo waitFor t.pop(0)
#       echo waitFor t.pop()

#       # waitFor t.acquire()
#       # t.release()
#       echo "pop!"
#     proc doput() =
#       registerChronosCleanup()
#       echo "put waiting..."
#       # waitFor t.acquire()
#       # t.release()
#       # waitFor sleepAsync(10.milliseconds)
#       # waitFor t.put(0, false)
#       t.add true
#       echo "put!"
#     createThread(t1, dopop)
#     createThread(t2, doput)
#     joinThreads(t1, t2)
#   proc run() =
#     for _ in 0..100:
#       test()
#   for i in 0..100:
#     echo i
#     run()
#   echo "finished"
