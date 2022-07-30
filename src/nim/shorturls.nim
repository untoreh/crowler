import
  zstd / [compress, decompress],
  hashes,
  uri,
  os

type BString* = string

type Zstd = object
  c: ptr ZSTD_CCtx
  d: ptr ZSTD_DCtx

const clevel = 2
var z {.threadvar.}: Zstd

when defined(gcDestructors):
  proc `=destroy`(z: var Zstd) =
    if not z.c.isnil:
      discard free_context(z.c)
    if not z.d.isnil:
      discard free_context(z.d)

proc initZstd*() =
  z.c = new_compress_context()
  z.d = new_decompress_context()

proc toBString*(s: string): BString {.gcsafe.} =
  ## Compresses a string and encodes it into base64
  let v = compress(z.c, s, clevel)
  encodeUrl(cast[string](v))

proc toBString*(s: string, _: static[bool]): BString {.gcsafe.} =
  ## Keep file extension
  let pos = s.searchExtPos
  if unlikely(pos == -1):
    s.toBString
  else:
    let v = compress(z.c, s[0..<pos], clevel)
    encodeUrl(cast[string](v) & s[pos..^1])

proc toString*(s: BString): string {.gcsafe.} =
  let
    v = decodeUrl(s)
    dv = decompress(z.d, v)
  cast[string](dv)

proc toString*(s: BString, _: static[bool]): string {.gcsafe.} =
  let
    v = decodeUrl(s)
    pos = v.searchExtPos
  let dv = decompress(z.d, v[0..<pos])
  cast[string](dv) & v[pos..^1]

converter asBString*(s: string): BString {.gcsafe.} =
  result = s

when isMainModule:
  import uri
  initZstd()
  let bs = "KLUv%2FSBLWQIAaHR0cHM6Ly9hMC5hd3NzdGF0aWMuY29tL2xpYnJhLWNzcy9pbWFnZXMvbG9nb3MvYXdzX2xvZ29fc21pbGVfMTIwMHg2MzAucG5n".decodeUrl.asBString
  # echo bs.toString()
