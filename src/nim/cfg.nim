import os,
       logging,
       uri,
       strutils,
       macros,
       sugar

import ./cfg_base
import parsetoml
export cfg_base

type ConfigObj {.partial.} = object
  websiteName*: string
  websiteDomain*: string
  websiteScheme*: string
  websitePort*: int
  websitetitle*: string
  websiteDescription*: string
  websiteContact*: string
  websiteCustomPages*: seq[string]
  ## Used by AMP to check if an asset file belongs to a "local" site
  websiteAllDomains*: seq[string]
  sitePath*: string
  siteAssetsPath*: Uri
  siteAssetsDir*: Uri
  dataPath*: string
  websitePath*: string
  websiteUrl*: Uri
  dataAssetsPath*: string
  dataAdsPath*: string
  assetsPath*: string
  defaultImage*: string
  defaultImageMime*: string
  cssBunUrl*: string
  cssCritRelUrl*: string
  jsRelUrl*: string
  logoRelDir*: Uri
  logoRelUrl*: string
  logoSmallUrl*: string
  logoIconUrl*: string
  logoDarkUrl*: string
  logoDarkSmallUrl*: string
  logoDarkIconUrl*: string
  faviconPngUrl*: string
  faviconSvgUrl*: string
  applePng180Url*: string
  ## Size (in bytes) of the excerpt
  articleExcerptSize*: int
  translationFlagsPath*: string
  translationFlagsRelUrl*: Uri
  websiteUrlImg*: Uri
  sonicBacklog*: string
  ## Period in seconds, after which an article can be removed
  cleanupAge*: int
  ## Minimum number of hits an article has to have to avoid cleanup
  cleanupHits*: uint

let configPath = PROJECT_PATH / "config" / os.getenv("CONFIG_NAME") & ".toml"
let tomlConfig = parseFile(configPath)
var configState = ConfigObj()
let config* = configState.addr

macro getConfig(k: static[string]): string =
  quote do:
    tomlConfig[`k`].getStr()

macro setConfig(k: static[string]) =
  let sym = ident(k)
  quote do:
    if tomlConfig.hasKey(`k`):
      config.`sym` = getConfig(`k`)
    else: raise newException(ValueError, "No value found for config item " & `k`)

macro setConfig[T](k: static[string], v: T) =
  let sym = ident(k)
  quote do:
    config.`sym` = `v`

template fromConfig(k: static[string], val, mut) =
  let v = try: getConfig(k) except ValueError: val
  setConfig(k, mut(v))

template putConfig(k: static[string], mut) =
  let v = getConfig(k)
  setConfig(k, mut(v))

proc doSplit(s: string): seq[string] = s.split(",")


setConfig("website_name")
setConfig("website_domain")
setConfig("website_scheme")
doassert $config.website_scheme in ["http://", "https://"]
putConfig("website_port", parseInt)
setConfig("website_title")
setConfig("website_description")
setConfig("website_contact")
fromConfig("website_custom_pages", os.getenv("WEB_CUSTOM_PAGES"), doSplit)
fromConfig("website_alldomains", os.getenv("WEB_DOMAINS"), doSplit)

when not declared(SERVER_MODE):
  const SERVER_MODE* {.booldefine.} = os.getenv("SERVER_MODE", "1").parseBool

const
  SITE_PATH* = PROJECT_PATH / "site"
  NOTO_FONT_URL* = "https://fonts.googleapis.com/css2?family=Noto+Serif+Display:ital,wght@0,100;0,300;0,700;1,100;1,300&family=Noto+Serif:ital,wght@0,400;0,700;1,400&family=Petrona:ital,wght@0,400;0,800;1,100;1,400&display=swap"
  DEFAULT_LANG_CODE* = "en"
  DEFAULT_LOCALE* = "en_US"
  TRANSLATION_WAITTIME* = 200 ## in milliseconds
  MAX_TRANSLATION_TRIES = 3
  TRANSLATION_ENABLED* = true
  TRANSLATION_TIMEOUT* = 0.25
  ZSTD_COMPRESSION_LEVEL* = 2
  AMP* = true
  MINIFY* = true
  RSS_N_ITEMS* = 20
  RSS_N_CACHE* = 1000
  ## Don't build yandex turbopages if the site is large
  YDX* = false
  IMG_VIEWPORT* = ["320w", "800w", "1920w"]
  IMG_SIZES* = ["122x122", "305x305", "733x733"]
  MENU_TOPICS* = 10          # max number of topics to display in menu
  SEARCH_ENABLED* = true
  SONIC_PASS* = "dmdm"
  SONIC_PORT* = 1491
  SONIC_ADDR* = "localhost"
  HTML_POST_SELECTOR* = "post-content"
  ## How long to wait for a single publishing task before failing, in seconds
  PUBLISH_TIMEOUT* = 10
  ## Interval between publishing tasks, in seconds
  PUB_TASK_THROTTLE* = 5
  ## how many related articles to display at the bottom of an article page.
  N_RELATED* = 3
  ## Number of articles (1 per topic) to display on the homepage
  HOME_ARTS* = 10

  # These are useless in server mode
  TRANSLATION_TO_FILE* = true
  MAX_DIR_FILES* = 10
  # not implemented
  TRENDS* = false

config.siteAssetsPath = BASE_URL / "assets" / config.websiteName
config.siteAssetsDir = BASE_URL / SITE_PATH / "assets" / config.websiteName
config.dataPath = PROJECT_PATH / "data"
config.websitePath = config.dataPath / "sites" / config.websiteName
config.websiteUrl = parseUri(config.websiteScheme & (config.websiteDomain & WEBSITE_DEBUG_PORT))
config.dataAssetsPath = config.dataPath / "assets" / config.websiteName
config.dataAdsPath = config.dataPath / "ads" / config.websiteName
config.assetsPath = PROJECT_PATH / "src" / "assets"
config.defaultImage = config.assetsPath / "image.svg"
config.defaultImageMime = "image/svg+xml"
config.cssBunUrl = $(config.siteAssetsPath / "bundle.css")
config.cssCritRelUrl = $(config.siteAssetsDir / "bundle-crit.css")
config.jsRelUrl = $(config.siteAssetsPath / "bundle.js")
config.logoRelDir = BASE_URL / "assets" / "logo" / config.websiteName
config.logoRelUrl = $(config.logoRelDir / "logo.svg")
config.logoSmallUrl = $(config.logoRelDir / "logo-small.svg")
config.logoIconUrl = $(config.logoRelDir / "logo-icon.svg")
config.logoDarkUrl = $(config.logoRelDir / "logo-dark.svg")
config.logoDarkSmallUrl = $(config.logoRelDir / "logo-small-dark.svg")
config.logoDarkIconUrl = $(config.logoRelDir / "logo-icon-dark.svg")
config.faviconPngUrl = $(config.logoRelDir / "logo-icon.png")
config.faviconSvgUrl = $(config.logoRelDir / "logo-icon.svg")
config.applePng180Url = $(config.logoRelDir / "apple-touch-icon.png")
config.articleExcerptSize = 300
config.translationFlagsPath = config.assetsPath / "flags-sprite.css"
config.translationFlagsRelUrl = config.siteAssetsPath / "flags-sprite.css"
config.websiteUrlImg = parseUri(config.websiteDomain & WEBSITE_DEBUG_PORT) / "i"
config.sonicBacklog = config.dataPath / "sonic" / "backlog.txt"
config.cleanupAge = 3600 * 24 * 30 * 4
config.cleanupHits = 2

static: echo "Project Path is '" & PROJECT_PATH & "'"
