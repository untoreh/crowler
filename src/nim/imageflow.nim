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
  pyhttp

const
  IF_VERSION_MAJOR: uint32 = 3
  IF_VERSION_MINOR: uint32 = 0
  BUFFER_SIZE = 10 * 1024 * 1024
  RES_BUFFER_SIZE = 1 * 1024 * 1024
  MAX_BUFFERS = 16

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
  proc `=destroy`(c: var IFLContext) {.nimcall.} =
    imageflow_context_destroy(c.p)

const
  outputIoId = 0
  inputIoId = 1
var
  ctx {.threadvar.}: IFLContext
  outputBuffer {.threadvar.}: ptr ptr uint8
  outputBufferLen {.threadvar.}: ptr csize_t
var
  resPtr {.threadvar.}: ptr ptr uint8
  resLen {.threadvar.}: ptr csize_t

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

threadVars(
    (cmd, cmdSteps, cmdStr, JsonNode),
    (cmdKind, cmdValue, string),
    (status, int64),
    (resBuffer, seq[uint8]),
    (resBufferLen, csize_t)
)

when false:
  const buildMethod = "v1/build"
const execMethod = "v1/execute"

proc initCmd() =
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

proc setCmd(v: string) {.inline.} = cmdStr["value"] = %v

proc initImageFlow*() =
  outputBuffer = create(ptr uint8)
  outputBufferLen = create(csize_t)
  resPtr = create(ptr uint8)
  resLen = create(csize_t)

  initCmd()
  resBuffer = newSeq[uint8](RES_BUFFER_SIZE)
  resBufferLen = RES_BUFFER_SIZE
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
  doassert ctx.check

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
      await httpGet(src)
      # (await fetch(HttpSessionRef.new(), parseUri(src))).data.bytesToString
    elif fileExists(src):
      await readFileAsync(src)
    else:
      ""

proc getMime(): string =
  ($resPtr[].toOA(resLen[].int).getJsonVal(
      "data.job_result.encodes[0].preferred_mime_type")).strip(
          chars = {'"'})

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
  discard imageflow_json_response_read(ctx.p, json_res,
                                       status.addr,
                                       resPtr,
                                       resLen)
  defer: doassert imageflow_json_response_destroy(ctx.p, json_res)

  var mime: string
  if status != 200:
    let msg = resPtr[].toString(resLen[].int)
    debug "imageflow: conversion failed {msg}"
    doassert ctx.check
  else:
    mime = getMime()
  discard imageflow_context_get_output_buffer_by_id(
      ctx.p,
      outputIoId,
      outputBuffer,
      outputBufferLen)
  doassert ctx.check
  result = (outputBuffer[].toString(outputBufferLen[].int), mime)

proc processImg*(input: string, mtd = execMethod): (string, string) =
  return doProcessImg(input, mtd)

when isMainModule:
  initImageFlow()
  let img = "https://external-content.duckduckgo.com/iu/?u=https%3A%2F%2Fwww.nj.com%2Fresizer%2Fmg42jsVYwvbHKUUFQzpw6gyKmBg%3D%2F1280x0%2Fsmart%2Fadvancelocal-adapter-image-uploads.s3.amazonaws.com%2Fimage.nj.com%2Fhome%2Fnjo-media%2Fwidth2048%2Fimg%2Fsomerset_impact%2Fphoto%2Fsm0212petjpg-7a377c1c93f64d37.jpg&f=1&nofb=1"
  # let img = PROJECT_PATH / "vendor" / "imageflow.dist" / "data" / "cat.jpg"
  let data = getImg(img, kind = urlsrc)
  doassert data.addImg
  let query = "width=100&height=100&mode=max"
  let (i, mime) = processImg(query)
