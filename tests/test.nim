import macros

# var initializers {.threadvar.}: seq[proc(): void]

macro dorun(bn: static[string], vn: untyped): untyped =
  let procname = ident("init" & $vn)
  echo procname
  # quote do:
  #   # var `varname`* {.threadvar.}: string
  #   proc `procname()` =
  #     checkNil(config)
  #     let path = config.dataAdsPath / `basename`
  #     # if fileExists(path):
  #     #   `varname` = readFile(path)
  #   initializers.add `procname`

dorun("asd", PLS)
