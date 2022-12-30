import std/[json, macros, sequtils, uri]
import types, utils, cfg, translate_types

type
  Icon = object
    json: JsonNode
    src: JsonNode
    sizes: JsonNode
    typ: JsonNode
    purpose: JsonNode
  RelApp = object
    json: JsonNode
    platform: JsonNode
    url: JsonNode
  PwaManifestObj = object
    json: JsonNode
    schema: JsonNode
    name: JsonNode
    shortName: JsonNode
    startUrl: JsonNode
    display: JsonNode
    backgroundColor: JsonNode
    description: JsonNode
    lang: JsonNode
    direction: JsonNode
    icons: seq[Icon]
    relatedApplications: seq[RelApp]
  PwaManifest = ref PwaManifestObj


converter toJson(s: string): JsonNode = return newJString(s)

macro setField(man, k, j) =
  ## This macro ensures that the key `k` is correct and the same as a field, and as JsonNode string key
  let ks = if k == ident("schema"): "$schema" elif k == ident(
      "typ"): "type" else: k.repr
  quote do:
    `man`.json[`ks`] = `j`
    `man`.`k` = `man`.json[`ks`]

proc newIcon(src, sizes, typ: string, purpose = "any"): Icon =
  result.json = newJObject()
  result.setField src, src
  result.setField sizes, sizes
  result.setField typ, typ
  result.setField purpose, purpose

proc newRelApp(platform, url: string): RelApp =
  result.json = newJObject()
  result.setField platform, platform
  result.setField url, url

proc setRelApp(p: PwaManifest, plat, url: string) =
  p.relatedApplications.add newRelApp(plat, url)
  const k = "related_applications"
  if not (k in p.json):
    p.json[k] = newJarray()
  p.json[k].add p.icons[^1].json

proc setIcon(p: PwaManifest, src, sizes, typ: string, purpose = "any") =
  p.icons.add newIcon(src, sizes, typ, purpose)
  const k = "icons"
  if not (k in p.json):
    p.json[k] = newJarray()
  p.json[k].add p.icons[^1].json

func newPwa(name, startUrl: string, shortName = "",
            description = "", lang = "en"): PwaManifest =
  result = PwaManifest()
  result.json = newJObject()
  result.setField schema, "https://json.schemastore.org/web-manifest-combined.json"
  result.setField name, name
  result.setField short_name, something(shortName, name)
  result.setField display, "standalone"
  result.setField background_color, "$fff"
  result.setField description, description
  result.setField start_url, startUrl
  result.setField lang, lang
  result.setField direction, "auto"

proc siteManifest*(): string =
  let pwa = newPwa(name = config.websiteTitle, startUrl = "/",
      shortName = config.websiteName, description = config.websiteDescription)
  pwa.setIcon(src = config.faviconSvgUrl, sizes = "48x48 72x72 96x96 128x128 256x256 512x512", typ = "svg")
  return $pwa.json

import karax/[vdom, karaxdsl]
func pwaLink*(): VNode =
     buildHtml(link(rel="manifest", href="/manifest.json"))

when isMainModule:
  echo pwaLink()
