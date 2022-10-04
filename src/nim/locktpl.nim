import locks
export locks

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
        var store: name[K, V] # FIXME: this is incompatible with `notnil` pragma
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

    iterator pairs*[K, V](tbl: `Lock name`[K, V]): (K, V) =
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

    proc pop*[K, V](tbl: `Lock name`, k: K, v: var V): bool =
        withLock(tbl.lock):
            result = tbl.storage.pop(k, v)

template lockedList*(name: untyped): untyped {.dirty.} =
    type
        `Lock name Obj`[T] = object
            lock: Lock
            storage {.guard: lock.}: name[T]
        `Lock name`*[T] = ptr `Lock name Obj`[T]

    proc `lock name Impl`*[T](store: name[T]): `Lock name`[T] =
        result = createShared(`Lock name Obj`[T])
        initLock(result.lock)
        withLock(result.lock):
            result.storage = store

    template `init Lock name`*[T](args: varargs[untyped]): `Lock name`[T] =
        var store: name[T] # FIXME: this is incompatible with `notnil` pragma
        store = when compiles(`init name`):
                    when varargsLen(args) > 0:
                        `init name`[T](args)
                    else:
                        `init name`[T]()
                elif compiles(`new name`):
                    when varargsLen(args) > 0:
                        `new name`[T](args)
                    else:
                        `new name`[T]()
                else:
                    `name`[T]()
        `lock name Impl`[T](store)

    iterator items*[T](tbl: `Lock name`[T]): T =
        withLock(tbl.lock):
            for v in tbl.storage:
                yield v

    proc `[]=`*[T](tbl: `Lock name`[T], idx: Natural, v: T) =
        withLock(tbl.lock):
            tbl.storage[idx] = v

    proc `[]`*[T](tbl: `Lock name`[T], idx: Natural): T =
        withLock(tbl.lock):
            result = tbl.storage[idx]

    proc contains*[T](tbl: `Lock name`[T], v: T): bool =
        withLock(tbl.lock):
            result = v in tbl.storage

    proc clear*[T](tbl: `Lock name`[T]) =
        withLock(tbl.lock):
            clear(tbl.storage)

    proc len*[T](tbl: `Lock name`[T]): int =
        withLock(tbl.lock):
            result = tbl.storage.len

    proc get*[T](tbl: `Lock name`[T], idx: Natural, def: T): T =
        withLock(tbl.lock):
            result = tbl.storage.getOrDefault(k, def)

    proc get*[T](tbl: `Lock name`[T], idx: Natural): T =
        withLock(tbl.lock):
            result = tbl.storage.get(idx)

    proc del*(tbl: `Lock name`, idx: Natural) =
      withLock(tbl.lock):
        {.cast(gcsafe).}:
          tbl.storage.del(k)

    proc pop*[T](tbl: var `Lock name`, idx: Natural, v: var T): bool =
        withLock(tbl.lock):
            result = tbl.storage.pop(idx, v)

    proc add*[T](tbl: var `Lock name`[T], v: T) =
      withLock(tbl.lock):
        tbl.storage.add v

    proc addFirst*[T](tbl: var `Lock name`[T], v: T) =
      withLock(tbl.lock):
        tbl.storage.addFirst v

    proc addLast*[T](tbl: var `Lock name`[T], v: T) =
      withLock(tbl.lock):
        tbl.storage.addLast v

    proc popFirst*[T](tbl: `Lock name`[T]): T =
      withLock(tbl.lock):
        result = tbl.storage.popFirst

    proc popLast*[T](tbl: `Lock name`[T]): T =
      withLock(tbl.lock):
        result = tbl.storage.popLast

    proc `$`*(tbl: `Lock name`): string =
      withLock(tbl.lock):
        result = $tbl.storage

when isMainModule:
    import tables, lrucache
    lockedStore(LruCache)
    let c = newLruCache[string, string](100)
    # let x = initLockLruCache[string, string](100)
    # x["a"] = "123"
    # echo x["a"]
    # echo typeof(x)
    # echo c.lcheckorput("asd", "pls")
