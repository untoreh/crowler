import os,
       logging,
       uri,
       strutils

const cfg_path = currentSourcePath().splitPath()[0]

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
setLogFilter(logLevel)
static: echo "cfg: debug level set to: " & $logLevelMacro

export logging

const
    USE_PROXIES* = true
    PROXY_EP* = "socks5://localhost:8877"
    PROJECT_PATH* = joinPath(cfg_path, "..", "..")
    WEBSITE_DOMAIN* = "localhost"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN)
    WEBSITE_TITLE* = "wsl"
    WEBSITE_DEBUG_PORT* = "8080"
    WEBSITE_CONTACT* = "contact@wsl"
    WEBSITE_TWITTER* = "https://twitter.com/wsl"
    WEBSITE_FACEBOOK* = "wslfb"
    WEBSITE_PINTEREST* = "wslpinterest"
    WEBSITE_WEIBO* = "wslweibo"
    WEBSITE_REDDIT* = "wslreddit"
    WEBSITE_SOCIAL* = [WEBSITE_TWITTER, WEBSITE_FACEBOOK, WEBSITE_PINTEREST, WEBSITE_WEIBO, WEBSITE_REDDIT]
    SITE_PATH* = joinPath(PROJECT_PATH, "site")
    DATA_PATH* = PROJECT_PATH / "data"
    ASSETS_PATH* = PROJECT_PATH / "src" / "assets"
    LOGO_DIR = ASSETS_PATH / "logo"
    CSS_REL_URL * = "/bundle.css"
    LOGO_PATH* = os.joinPath(LOGO_DIR, "logo.svg")
    LOGO_URL* = WEBSITE_URL / LOGO_DIR / "logo.png"
    LOGO_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small.svg")
    LOGO_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon.svg")
    LOGO_DARK_PATH* = os.joinPath(LOGO_DIR, "logo-dark.svg")
    LOGO_DARK_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small-dark.svg")
    LOGO_DARK_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon-dark.svg")
    FAVICON_PNG* = LOGO_DIR / "logo-icon.png"
    FAVICON_SVG* = LOGO_DIR / "logo-icon.svg"
    MAX_DIR_FILES* = 10
    ARTICLE_EXCERPT_SIZE* = 300 ## Size (in bytes) of the excerpt
    DB_SIZE* = 1024 * 1024 * 1024
    DB_PATH* = DATA_PATH / "translate.db"
    MAX_TRANSLATION_TRIES* = 3
    DEFAULT_LANG_CODE* = "en"
    DEFAULT_LOCALE* = "en_US"
    TRANSLATION_ENABLED* = true
    TRANSLATION_TIMEOUT* = 0.25
    TRANSLATION_FLAGS_PATH* = ASSETS_PATH / "flags-sprite.css"
    ZSTD_COMPRESSION_LEVEL* = 2
    TRANSLATION_TO_FILE* = true
    AMP* = true
    YDX* = false ## Don't build yandex turbopages if the site is large
    MINIFY* = true
    RSS* = true
    RSS_N_ITEMS* = 10
