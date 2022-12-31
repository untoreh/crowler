import std/[os, times, strformat, tables, macros, sugar, hashes, sets, sequtils, locks]

import
  utils,
  cfg,
  translate_types,
  data

const MAX_CACHE_ENTRIES = 16

# Slations holds recent translations
var slations*: LockTable[string, string]

proc initSlations*(comp = true) {.gcsafe.} =
  if slations.isnil:
    slations = initLockTable[string, string]()

var trans*: LockDB

proc initTranslateDb*(comp = false) =
  if trans.isnil:
    trans = init(LockDB, config.websitePath / "translate.db",
        ttl = initDuration(days = 300), ignoreErrors = true)
    if comp: trans.compact(purgeOnError = true)
  else:
    assert(false, "Translate DB already initialized.")

func trKey*(pair: langPair, txt: string): string {.inline.} =
  pair.src & pair.trg & txt

proc setFromDB*(pair: langPair, el: auto): (bool, int) =
  let
    txt = getText(el)
    k = trKey(pair, txt)

  assert not slations.isnil, "setfromdb: slations should not be nil"
  # try temp cache before db
  if k in slations:
    setText(el, slations[k])
    (true, txt.len)
  else:
    let t = trans.getUnchecked(k)
    if t != "":
      setText(el, t)
      (true, txt.len)
    else:
      (false, txt.len)

proc saveToDB*(tr = trans, slations = slations,
        force = false) {.gcsafe.} =
  logall "slations: {slations.len} - force: {force}"
  if slations.len > 0 and (force or slations.len > MAX_CACHE_ENTRIES):
    logall "db: saving to db"
    tr.put(slations)
    debug "db: clearing slations ({slations.len})"
    slations.clear()
  logall "db: finish save"

when isMainModule:
  import strutils, sequtils, sugar
  # let pair = (src: "en", trg: "it")
  # trans[(pair, "hello")] = "ohy"
  # let v = trans[(pair, "hello")]
  # echo v
  trans["pls"] = "wow"
  echo trans["pls"]
