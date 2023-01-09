import json_serialization
import os
import tables
import json

import "../src/nim/cfg"
import "../src/nim/lazyjson"

let sites_json = readFile(PROJECT_PATH / "config" / "sites.json")

var (reader, _) = getJsonReader(sites_json)
let sites = reader.readValue(JsonNode)
echo sites.len
for (domain, name_port) in sites.pairs():
  echo domain

# let input = sites_json.unsafeMemoryInput
# var reader = init(JsonReader[DefaultFlavor], input)
# echo reader.readValue(JsonNode)
