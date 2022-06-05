template defineStore*(name: untyped): untyped {.dirty.} =
    type
        `Store name Obj`[K, V] = object
            storage: name[K, V]
        `Store name`*[K, V] = ptr `Store name Obj`[K, V]

    proc `store name Impl`*[K, V](store: name[K, V]): `Store name`[K, V] =
        result = createShared(`Store name Obj`[K, V])
        result.storage = store

    template `init Store name`*[K, V](args: varargs[untyped]): `Store name`[K, V] =
        var store = when compiles(`init name`):
                    when varargsLen(args) > 0:
                        `init name`[K, V](args)
                    else:
                        `init name`[K, V]()
                elif compiles(`new name`):
                    when varargsLen(args) > 0:
                        `new name`[K, V](args)
                    else:
                        `new name`[K, V]()[]
                else:
                    `name`[K, V]()
        `store name Impl`(store)

    proc contains*[K, V](s: `Store name`[K, V], k: K): bool =
        k in s.storage

when isMainModule:
    import tables, lrucache
    defineStore(LruCache)
    let s = initStoreLruCache[string, string](100)
    echo "asd" in s
