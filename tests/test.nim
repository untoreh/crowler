import macros


var enabled {.compileTime.} = false

proc acquire() =
  enabled = true

proc release() =
  enabled = false

proc test(): bool {.compileTime.} = enabled

proc run() =
  when not enabled:
    {.error: "Lock not acquired!".}

run()
