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

export logging

const
    USE_PROXIES* = true
    PROXY_EP* = "socks5://localhost:8877"
    PROJECT_PATH* = joinPath(cfg_path, "..", "..")
    WEBSITE_DOMAIN* = "localhost"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN)
    WEBSITE_TITLE* = "wsl"
    WEBSITE_DEBUG_PORT* = "8080"
    SITE_PATH* = joinPath(PROJECT_PATH, "site")
    DATA_PATH* = PROJECT_PATH / "data"
    ASSETS_PATH* = PROJECT_PATH / "src" / "assets"
    LOGO_DIR = ASSETS_PATH / "logo"
    LOGO_PATH* = os.joinPath(LOGO_DIR, "logo.svg")
    LOGO_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small.svg")
    LOGO_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon.svg")
    LOGO_DARK_PATH* = os.joinPath(LOGO_DIR, "logo-dark.svg")
    LOGO_DARK_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small-dark.svg")
    LOGO_DARK_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon-dark.svg")
    MAX_DIR_FILES* = 10
    ARTICLE_EXCERPT_SIZE* = 300 ## Size (in bytes) of the excerpt
    DB_SIZE* = 1024 * 1024 * 1024
    DB_PATH* = DATA_PATH / "translate.db"
    MAX_TRANSLATION_TRIES* = 3
    DEFAULT_LANG_CODE* = "en"
    DEFAULT_LOCALE* = "en_US"
    TRANSLATION_ENABLED* = true
    TRANSLATION_TIMEOUT* = 0.25
    ZSTD_COMPRESSION_LEVEL* = 2
    WRITE_TO_FILE* = true
    TWITTER_HANDLE = "@VPSG"
