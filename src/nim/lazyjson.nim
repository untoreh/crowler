import
  algorithm,
  json,
  json_serialization,
  json_serialization/lexer,
  faststreams/inputs,
  std/enumerate,
  strutils,
  std/options

import utils

export options, nre, strutils, json_serialization, json

## Me not giving a f about abstractions
type
  Octet = byte | char | uint8
  Buffer = seq[Octet] | openarray[Octet] | string | ptr[Octet] | UncheckedArray[Octet]

proc findJNode(node: JsonNode, keys: var seq[JsonNode]): JsonNode =
  if keys.len == 0:
    return node
  let target = keys.pop()
  case target.kind:
    of JInt:
      let idx = target.to(int)
      if idx + 1 > node.len:
        return newJNull()
      else:
        return findJNode(node[idx], keys)
    of JString:
      let k = target.to(string)
      if k in node:
        return findJNode(node[k], keys)
      else:
        return newJNull()
    else:
      return newJNull()


proc jsonItems[F](r: var JsonReader[F], keys: var seq[JsonNode]): JsonNode =
  doassert keys.len > 0
  let target = keys.pop()
  case r.lexer.tok():
    of tkCurlyLe:
      for k in r.readObjectFields(JsonNode):
        if k != target:
          r.skipToken(r.lexer.tok)
        else:
          if keys.len > 0:
            return r.jsonItems(keys)
          else:
            return r.readValue(JsonNode)
    of tkBracketLe:
      assert target.kind == JInt
      let idx = target.to(int)
      for (n, v) in enumerate(readArray(r, JsonNode)):
        if n != idx:
          continue
        else:
          if keys.len > 0:
            return v.findJNode(keys)
          else:
            return v
    else:
      return r.readValue(JsonNode)



proc getJsonReader*(s: Buffer): auto =
  ## Input should be closed after the JsonReader is discarded.
  let input = s.unsafeMemoryInput
  var reader = init(JsonReader[DefaultFlavor], input)
  return (reader, input)

proc getJsonVal[T](s: Buffer, revkeys: var seq[JsonNode]): T =
  # `revkeys` are supposed to be already reversed since we `pop`
  var (reader, input) = getJsonReader(s)
  defer: input.close()
  return reader.jsonItems(revkeys).to(T)

template getJsonVal*[T](s: auto, keys: static[string]): T =
  var revkeys: seq[JsonNode]
  var split = keys.split(".")
  split.reverse
  for k in split:
    let m = k.match(sre "(.*?)\\[([0-9]+)\\]")
    if m.isSome:
      revkeys.add %m.get().captures[1].parseInt
      revkeys.add %m.get().captures[0]
    else:
      revkeys.add %k
  getJsonVal[T](s, revkeys)

proc getJsonVal*(s: Buffer, keys: static string): JsonNode =
  getJsonVal[JsonNode](s, keys)
