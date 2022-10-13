import std/[os, posix, strutils]

let memLimit* = os.getEnv("MEM_LIMIT_MB", "1792").parseInt

proc getCurrentMem*(): int =
  ## KBs of used mem
  var r: Rusage
  getrusage(RUSAGE_SELF, r.addr)
  return r.ru_maxrss

proc memLimitReached*(limit = memLimit): bool =
  getCurrentMem().div(1_000) >= limit

