when isMainModule:
  import json
  let j = newJObject()
  j["wow"] = %*{"asd": {"nice": "eheh"}}
  echo getJsonVal[JsonNode]($j, "wow.asd.nice")
