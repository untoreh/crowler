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
  let bs = "%28%B5%2F%FD+S%5D%02%00%A2%84%10%16%801%0E%FF%D4%92%C9%BFr%A5%A9%8F%04%F4%98%A5Ys.%81DCO%CA%A8%D8%B4T4y%83L%86%AD%E2%D4%A8%D3%92%5D0%86%82xg%B2P%E0%AD%CB%80%3Dg%7B%B0%13i%8B%F0%BD%F7%1F%CD%CE%A9%01%00%2B%C5%84%02"
  #echo bs.toString()
