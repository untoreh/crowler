import
  vendor/imageflow_plumbing,
  strformat,
  json,
  tables,
  std/uri,
  hashes,
  os,
  chronos

import
  cfg,
  utils,
  lazyjson,
  nativehttp

const
  IF_VERSION_MAJOR: uint32 = 3
  IF_VERSION_MINOR: uint32 = 0

type
  IFLContext = object
    p: pointer
  IFLMethod = enum
    crop_whitespace,
    command_string,
    constrain,
    encode,
    decode
  Source* = enum filesrc = "file", urlsrc = "url", bytesrc = "byte_array",
          buffersrc = "output_buffer"

when defined(gcDestructors):
  proc `=destroy`*(c: var IFLContext) {.nimcall.} =
    imageflow_context_destroy(c.p)

const
  outputIoId = 0
  inputIoId = 1

threadVars(
  (ctx, IFLContext),
  (cmd, cmdSteps, cmdStr, JsonNode),
  (cmdKind, cmdValue, string),
  (status, int64),
)

when false:
  const buildMethod = "v1/build"
const execMethod = "v1/execute"

proc check(c: IFLContext): bool =
  let msg = case imageflow_context_error_as_exit_code(c.p):
    of 0: ""
    of 64: "Invalid usage (graph invalid, node argument invalid, action not supported)"
    of 65: "Invalid Json, Image malformed, Image type not supported"
    of 66: "Primary or secondary file or resource not found."
    of 69: "Upstream server errored or timed out"
    of 70: "Possible bug: internal error, custom error, unknown error, or no graph solution found"
    of 71: "Out Of Memory condition (malloc/calloc/realloc failed)."
    of 74: "I/O Error"
    of 77: "Action forbidden under imageflow security policy"
    of 402: "License error"
    of 401: "Imageflow server authorization required"
    else:
      "Unknown Error"
  if (msg != ""):
    if imageflow_context_error_recoverable(c.p) and
       imageflow_context_error_try_clear(c.p):
      return false
    else:
      raise newException(ValueError, msg)
  return true


proc initCmd() =
  if not cmd.isnil:
    return
  cmd = newJObject()
  cmdStr = newJObject()
  cmdSteps = %[]
  cmdKind = "ir4"
  cmdValue = ""
  cmd["framewise"] = newJObject()
  cmd["framewise"]["steps"] = cmdSteps
  cmdSteps.add newJObject()
  cmdSteps[0]["command_string"] = cmdStr
  cmdStr["kind"] = %cmdKind
  cmdStr["value"] = %cmdValue
  # the input buffer always changes, it is incremental
  cmdStr["decode"] = %1
  # the first id is the `output_buffer`
  cmdStr["encode"] = %0

# not needed with endpoint `v1/execute`
# proc setIO*(u: string, kind = filesrc) =
#     cmd["io"] = %*[
#         {
#             "io_id": 0,
#             "direction": "in",
#             "io": {
#                 $kind: $u
#             }
#         },
#         {
#             "io_id": 1,
#             "direction": "out",
#             "io": "output_buffer"
#         }
#     ]

proc setCmd(v: string) {.inline.} =
  cmdStr["value"] = %v

proc initImageFlow*() =
  initCmd()
  if not imageflow_abi_compatible(IF_VERSION_MAJOR, IF_VERSION_MINOR):
    let
      mj = imageflow_abi_version_major()
      mn = imageflow_abi_version_minor()
      msg = fmt"Could not create imageflow context, requested version {IF_VERSION_MAJOR}.{IF_VERSION_MINOR} but found {mj}.{mn}"
    raise newException(LibraryError, msg)

  ctx.p = imageflow_context_create(IF_VERSION_MAJOR, IF_VERSION_MINOR)
  # NOTE: only needed with method v1/execute (probably)
  let b = imageflow_context_add_output_buffer(ctx.p, outputIoId)
  if not b: doassert ctx.check
  # discard imageflow_context_memory_allocate(ctx.p, BUFFER_SIZE.csize_t, "", 0)

proc reset(c: IFLContext) =
  imageflow_context_destroy(ctx.p)
  ctx.p = imageflow_context_create(IF_VERSION_MAJOR, IF_VERSION_MINOR)
  let b = imageflow_context_add_output_buffer(ctx.p, outputIoId)
  if not b: doassert ctx.check

proc addImg*(img: string): bool =
  ## a lock should be held here throughout the `processImg` call.
  if img == "": return false
  reset(ctx)
  doassert ctx.check
  let a = imageflow_context_add_input_buffer(
    ctx.p,
    inputIoId,
    # NOTE: The image is held in cache, but it might be collected
    cast[ptr uint8](img[0].unsafeAddr),
    img.len.csize_t,
    imageflow_lifetime_lifetime_outlives_context)
  if not a:
    doassert ctx.check
    cmdStr["decode"] = %inputIoId
  return true

proc getImg*(src: string, kind: Source): Future[string] {.async.} =
  return case kind:
    of urlsrc:
      (await get(src.parseUri, decode = false, proxied = false)).body
    elif fileExists(src):
      await readFileAsync(src)
    else:
      ""

proc getMime(s: openarray[byte]): string =
  ($s.getJsonVal("data.job_result.encodes[0].preferred_mime_type")).strip(chars = {'"'})

proc doProcessImg(input: string, mtd = execMethod): (string, string) =
  setCmd(input)
  let c = $cmd
  # debug "{hash(c)} - {c}"
  let json_res = imageflow_context_send_json(
      ctx.p,
      mtd,
      cast[ptr uint8](c[0].unsafeAddr),
      c.len.csize_t
    )
  var
    resp: ptr uint8
    respLen: csize_t

  discard imageflow_json_response_read(ctx.p, json_res,
                                       status.addr,
                                       resp.addr,
                                       respLen.addr)
  defer: doassert imageflow_json_response_destroy(ctx.p, json_res)
  checkNil(resp)

  var mime: string
  if status != 200:
    let msg = resp.toString(respLen.int)
    debug "imageflow: conversion failed {msg}"
    doassert ctx.check
  else:
    mime = getMime(resp.toOA(respLen.int))
  var
    outputBuffer: ptr uint8
    outputBufferLen: csize_t
  discard imageflow_context_get_output_buffer_by_id(
      ctx.p,
      outputIoId,
      outputBuffer.addr,
      outputBufferLen.addr)
  doassert ctx.check
  checkNil(outputBuffer)
  result = (outputBuffer.toString(outputBufferLen.int), mime)

proc processImg*(input: string, mtd = execMethod): (string, string) =
  initCmd()
  return doProcessImg(input, mtd)
