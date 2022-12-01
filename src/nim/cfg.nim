import os,
       logging,
       uri,
       strutils

import ./config/base
export base

const configName = os.getenv("CONFIG_NAME", "")
when configName == "dev":
  import ./config/dev
  export dev
elif configName == "wsl":
  import ./config/wsl
  export wsl
elif configName == "wsl":
  import ./config/wsl
  export wsl

const
  BASE_URL* = Uri()
  SITE_PATH* = PROJECT_PATH / "site"
  SITE_ASSETS_PATH* = BASE_URL / "assets" / WEBSITE_NAME
  SITE_ASSETS_DIR* = SITE_PATH / "assets" / WEBSITE_NAME
  DATA_PATH* = PROJECT_PATH / "data"
  DATA_ASSETS_PATH* = DATA_PATH / "assets" / WEBSITE_NAME
  DATA_ADS_PATH* = DATA_PATH / "ads" / WEBSITE_NAME
  ASSETS_PATH* = PROJECT_PATH / "src" / "assets"
  DEFAULT_IMAGE* = ASSETS_PATH / "image.svg"
  DEFAULT_IMAGE_MIME* = "image/svg+xml"
  CSS_BUN_URL* = $(SITE_ASSETS_PATH / "bundle.css")
  CSS_CRIT_PATH* = SITE_ASSETS_DIR / "bundle-crit.css"
  JS_REL_URL* = $(SITE_ASSETS_PATH / "bundle.js")
  LOGO_PATH* = BASE_URL / "assets" / "logo" / WEBSITE_NAME
  LOGO_URL* = $(LOGO_PATH / "logo.svg")
  LOGO_SMALL_URL* = $(LOGO_PATH / "logo-small.svg")
  LOGO_ICON_URL* = $(LOGO_PATH / "logo-icon.svg")
  LOGO_DARK_URL* = $(LOGO_PATH / "logo-dark.svg")
  LOGO_DARK_SMALL_URL* = $(LOGO_PATH / "logo-small-dark.svg")
  LOGO_DARK_ICON_URL* = $(LOGO_PATH / "logo-icon-dark.svg")
  FAVICON_PNG_URL* = $(LOGO_PATH / "logo-icon.png")
  FAVICON_SVG_URL* = $(LOGO_PATH / "logo-icon.svg")
  APPLE_PNG180_URL* = $(LOGO_PATH / "apple-touch-icon.png")
  MAX_DIR_FILES* = 10
  ARTICLE_EXCERPT_SIZE* = 300 ## Size (in bytes) of the excerpt
  TRANSLATION_WAITTIME* = 200 ## in milliseconds
  MAX_TRANSLATION_TRIES* = 3
  DEFAULT_LANG_CODE* = "en"
  DEFAULT_LOCALE* = "en_US"
  TRANSLATION_ENABLED* = true
  TRANSLATION_TIMEOUT* = 0.25
  NOTO_FONT_URL* = "https://fonts.googleapis.com/css2?family=Noto+Serif+Display:ital,wght@0,100;0,300;0,700;1,100;1,300&family=Noto+Serif:ital,wght@0,400;0,700;1,400&family=Petrona:ital,wght@0,400;0,800;1,100;1,400&display=swap"
  TRANSLATION_FLAGS_PATH* = ASSETS_PATH / "flags-sprite.css"
  TRANSLATION_FLAGS_REL* = SITE_ASSETS_PATH / "flags-sprite.css"
  ZSTD_COMPRESSION_LEVEL* = 2
  TRANSLATION_TO_FILE* = true
  AMP* = true
  YDX* = false                ## Don't build yandex turbopages if the site is large
  MINIFY* = true
  RSS* = true
  RSS_N_ITEMS* = 20
  RSS_N_CACHE* = 1000
  SERVER_MODE* = true
  WEBSITE_URL_IMG* = parseUri(WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT) / "i"
  IMG_VIEWPORT* = ["320w", "800w", "1920w"]
  IMG_SIZES* = ["122x122", "305x305", "733x733"]
  TRENDS* = false
  MENU_TOPICS* = 10           # max number of topics to display in menu
  SEARCH_ENABLED* = true
  SONIC_PASS* = "dmdm"
  SONIC_PORT* = 1491
  SONIC_ADDR* = "localhost"
  SONIC_BACKLOG* = DATA_PATH / "sonic" / "backlog.txt"
  HTML_POST_SELECTOR* = "post-content"
  PUBLISH_TIMEOUT* = 10       ## In seconds
  N_RELATED* = 3 # how many related articles to display at the bottom of an article page
  HOME_ARTS* = 10              # Number of articles (1 per topic) to display on the homepage

# Seconds between a `pub` job run
when not declared(CRON_TOPIC):
  const CRON_TOPIC* = 10
# Maximum minutes between a specific topic `pub` job run
when not declared(CRON_TOPIC_FREQ_MAX):
  const CRON_TOPIC_FREQ_MAX* = 3600 * 8
# Minimum minutes between a specific topic `pub` job run
when not declared(CRON_TOPIC_FREQ_MIN):
  const CRON_TOPIC_FREQ_MIN* = 3600
# Period in seconds, after which an article can be removed
when not declared(CLEANUP_AGE):
  const CLEANUP_AGE* = 3600 * 24 * 30 * 4
# Minimum number of hits an article has to have to avoid cleanup
when not declared(CLEANUP_HITS):
  const CLEANUP_HITS* = 2

static: echo "Project Path is '" & PROJECT_PATH & "'"
