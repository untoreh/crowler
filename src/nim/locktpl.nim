import locks
export locks
import utils

template lockedStore*(name: untyped): untyped {.dirty.} =
    type
        `Lock name Obj`[K, V] = object
            lock: Lock
            storage {.guard: lock.}: name[K, V]
        `Lock name`*[K, V] = ptr `Lock name Obj`[K, V]

    proc `lock name Impl`*[K, V](store: name[K, V]): `Lock name`[K, V] =
        result = createShared(`Lock name Obj`[K, V])
        initLock(result.lock)
        withLock(result.lock):
            result.storage = store

    template `init Lock name`*[K, V](args: varargs[untyped]): `Lock name`[K, V] =
        var store: name[K, V]
        store = when compiles(`init name`):
                    when varargsLen(args) > 0:
                        `init name`[K, V](args)
                    else:
                        `init name`[K, V]()
                elif compiles(`new name`):
                    when varargsLen(args) > 0:
                        `new name`[K, V](args)
                    else:
                        `new name`[K, V]()
                else:
                    `name`[K, V]()
        `lock name Impl`[K, V](store)

    iterator items*[K, V](tbl: `Lock name`[K, V]): (K, V) =
        withLock(tbl.lock):
            for (k, v) in tbl.storage.pairs():
                yield (k, v)

    iterator keys*[K, V](tbl: `Lock name`[K, V]): K =
        withLock(tbl.lock):
            for k in tbl.storage.keys():
                yield k

    proc `[]=`*[K, V](tbl: `Lock name`[K, V], k: K, v: V) =
        withLock(tbl.lock):
            tbl.storage[k] = v

    proc `[]`*[K, V](tbl: `Lock name`[K, V], k: K): V =
        withLock(tbl.lock):
            result = tbl.storage[k]

    proc contains*[K, V](tbl: `Lock name`[K, V], k: K): bool =
        withLock(tbl.lock):
            result = k in tbl.storage

    proc clear*[K, V](tbl: `Lock name`[K, V]) =
        withLock(tbl.lock):
            clear(tbl.storage)

    proc len*[K, V](tbl: `Lock name`[K, V]): int =
        withLock(tbl.lock):
            result = tbl.storage.len

    proc get*[K, V](tbl: `Lock name`[K, V], k: K, def: V): V =
        withLock(tbl.lock):
            result = tbl.storage.getOrDefault(k, def)

    proc get*[K, V](tbl: `Lock name`[K, V], k: K): V =
        withLock(tbl.lock):
            result = tbl.storage.get(k)

    proc del*[K](tbl: `Lock name`, k: K) =
      withLock(tbl.lock):
        {.cast(gcsafe).}:
          tbl.storage.del(k)

    proc pop*[K, V](tbl: var `Lock name`, k: K, v: var V): bool =
        withLock(tbl.lock):
            result = tbl.storage.pop(k, v)

when isMainModule:
    import tables, lrucache
    lockedStore(LruCache)
    let c = newLruCache[string, string](100)
    # let x = initLockLruCache[string, string](100)
    # x["a"] = "123"
    # echo x["a"]
    # echo typeof(x)
    echo c.lcheckorput("asd", "pls")
