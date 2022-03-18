import os,
       logging,
       uri

const cfg_path = currentSourcePath().splitPath()[0]

let logger* = newConsoleLogger(fmtStr = "[$time] - $levelname: ")

export logging

const
    PROJECT_PATH* = joinPath(cfg_path, "..", "..")
    WEBSITE_DOMAIN* = "localhost"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN)
    WEBSITE_TITLE* = "wsl"
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
