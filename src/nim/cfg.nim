import os,
       logging,
       uri,
       strutils

const releaseMode* = os.getenv("NIM", "") == "release"
const PROJECT_PATH = when releaseMode: ""
                 else: currentSourcePath().splitPath()[0] / ".." / ".."

let loggerObj = newConsoleLogger(fmtStr = "[$time] - $levelname: ")
let logger* = loggerObj.unsafeAddr

proc logLevelFromEnv(): auto =
    case os.getenv("NIM_DEBUG", "INFO").toUpper:
    of "ALL":
        lvlAll
    of "DEBUG":
        lvlDebug
    of "WARNING":
        lvlWarn
    of "ERROR":
        lvlError
    of "CRITICAL":
        lvlFatal
    of "NONE":
        lvlNone
    else:
        lvlInfo

let logLevel = logLevelFromEnv()
const logLevelMacro* = logLevelFromEnv()
proc initLogging*() = setLogFilter(logLevel)
initLogging()
static: echo "cfg: debug level set to: " & $logLevelMacro

export logging

const
    USE_PROXIES* = true
    PROXY_EP* = "socks5://localhost:8877"
    WEBSITE_DEBUG_PORT* = ":5050"
    WEBSITE_DOMAIN* = os.getenv("WEBSITE_DOMAIN", "wsl")
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "wsl"
    WEBSITE_DESCRIPTION* = "Everything about server hosting."
    WEBSITE_CONTACT* = "contact@wsl"
    WEBSITE_TWITTER* = "https://twitter.com/wsl"
    WEBSITE_FACEBOOK* = "wslfb"
    WEBSITE_PINTEREST* = "wslpinterest"
    WEBSITE_WEIBO* = "wslweibo"
    WEBSITE_REDDIT* = "wslreddit"
    WEBSITE_SOCIAL* = [WEBSITE_TWITTER, WEBSITE_FACEBOOK, WEBSITE_PINTEREST, WEBSITE_WEIBO, WEBSITE_REDDIT]
    SITE_PATH* = PROJECT_PATH / "site"
    SITE_ASSETS_DIR* = DirSep & "assets"
    DATA_PATH* = PROJECT_PATH / "data"
    ASSETS_PATH* = PROJECT_PATH / "src" / "assets"
    CSS_REL_URL* = SITE_ASSETS_DIR / "/bundle.css"
    JS_REL_URL* = SITE_ASSETS_DIR / "/bundle.js"
    LOGO_DIR* = WEBSITE_URL / SITE_ASSETS_DIR / "logo"
    LOGO_URL* = $(LOGO_DIR / "logo.svg")
    LOGO_SMALL_URL* = $(LOGO_DIR / "logo-small.svg")
    LOGO_ICON_URL* = $(LOGO_DIR / "logo-icon.svg")
    LOGO_DARK_URL* = $(LOGO_DIR / "logo-dark.svg")
    LOGO_DARK_SMALL_URL* = $(LOGO_DIR / "logo-small-dark.svg")
    LOGO_DARK_ICON_URL* = $(LOGO_DIR / "logo-icon-dark.svg")
    FAVICON_PNG_URL* = $(LOGO_DIR / "logo-icon.png")
    FAVICON_SVG_URL* = $(LOGO_DIR / "logo-icon.svg")
    MAX_DIR_FILES* = 10
    ARTICLE_EXCERPT_SIZE* = 300 ## Size (in bytes) of the excerpt
    MAX_TRANSLATION_TRIES* = 3
    DEFAULT_LANG_CODE* = "en"
    DEFAULT_LOCALE* = "en_US"
    TRANSLATION_ENABLED* = true
    TRANSLATION_TIMEOUT* = 0.25
    TRANSLATION_FLAGS_PATH* = ASSETS_PATH / "flags-sprite.css"
    TRANSLATION_FLAGS_REL* = "/" / SITE_ASSETS_DIR / "flags-sprite.css"
    ZSTD_COMPRESSION_LEVEL* = 2
    TRANSLATION_TO_FILE* = true
    AMP* = true
    YDX* = false                ## Don't build yandex turbopages if the site is large
    MINIFY* = true
    RSS* = true
    RSS_N_ITEMS* = 10
    RSS_N_CACHE* = 1000
    SERVER_MODE* = true
    # WEBSITE_IMG_PORT* = ":5051"
    # WEBSITE_URL_IMG* = initUri() / ("img" & "." & WEBSITE_DOMAIN) / WEBSITE_IMG_PORT
    WEBSITE_URL_IMG* = parseUri(WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT) / "i"
    IMG_VIEWPORT* = ["320w", "800w", "1920w"]
    IMG_SIZES* = ["122x122", "305x305", "733x733"]
    TRENDS* = false
    MENU_TOPICS* = 10 # max number of topics to display in menu
    SEARCH_ENABLED* = true
    SONIC_PASS* = "dmdm"
    SONIC_PORT* = 1491
    SONIC_ADDR* = "localhost"
    SONIC_BACKLOG* = DATA_PATH / "sonic" / "backlog.txt"
    HTML_POST_SELECTOR* = "post-content"
    PUBLISH_TIMEOUT* = 10 ## In seconds
    N_RELATED* = 3 # how many related articles to display at the bottom of an article page
    N_TOPICS* = 10 # Number of articles (1 per topic) to display on the homepage
    CRON_TOPIC* = 10 # Seconds between a `pub` job run
    CRON_TOPIC_FREQ* = 8 # Hours between a specific topic `pub` job run

static: echo "Data Path is " & PROJECT_PATH
