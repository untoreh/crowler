when isMainModule:
  import tables, lrucache
  lockedStore(LruCache)
  let c = newLruCache[string, string](100)
  let x = initLockLruCache[string, string](100)
  x["a"] = "123"
  echo x["a"]
  echo typeof(x)
  echo c.lcheckorput("asd", "pls")
