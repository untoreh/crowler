import nimpy,
       os,
       osproc,
       sets,
       sugar,
       strutils,
       strformat,
       tables,
       macros,
       locks,
       chronos

import
  cfg,
  types,
  translate_types,
  utils

when defined(translateProc):
  import translate_proc
  export translate_proc

const nativeTranslator* {.booldefine.}: bool = true

static: echo "loading translate_srv"

proc initSlator*(srv: service = default_service,
                 provider: string = "",
                 source: Lang = SLang,
                 targets: HashSet[Lang] = TLangs): Translator =
  result = create(TranslatorObj)
  result.name = srv

let
  srv = when nativeTranslator:
          import translate_native
          export translate_native
          native
        else:
          base_translator
  slatorObj = initSlator(srv)
  slator* = slatorObj.unsafeAddr

proc callTranslatorNative*(src: string, lang: langPair): Future[
    string] {.async.} =
  return await translate(src, lang.src, lang.trg)

const callTranslator* =
  when nativeTranslator:
    callTranslatorNative
  else:
    # NOTE: untested refactor
    import pyutils
    import quirks
    import translate_srv_py
    initSlatorPy(slatorObj)
