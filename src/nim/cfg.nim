import macros,
       macroutils,
       os,
       streams,
       parsexml,
       strutils,
       karax / [karaxdsl, vdom, vstyles],
       unicode,
       htmlgen,
       xmlparser

const cfg_path = currentSourcePath().splitPath()[0]

const
    PROJECT_PATH* = joinPath(cfg_path, "..", "..")
    WEBSITE_URL* = "http://localhost"
    WEBSITE_TITLE* = "wsl"
    SITE_PATH* = joinpath(PROJECT_PATH, "site")
    ASSETS_PATH* = os.joinPath(SITE_PATH, "assets")
    LOGO_DIR = os.joinPath(PROJECT_PATH, "src", "assets", "logo")
    LOGO_PATH* = os.joinPath(LOGO_DIR, "logo.svg")
    LOGO_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small.svg")
    LOGO_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon.svg")
    LOGO_DARK_PATH* = os.joinPath(LOGO_DIR, "logo-dark.svg")
    LOGO_DARK_SMALL_PATH* = os.joinPath(LOGO_DIR, "logo-small-dark.svg")
    LOGO_DARK_ICON_PATH* = os.joinPath(LOGO_DIR, "logo-icon-dark.svg")
    # TPL_PATH* = os.joinPath(SITE_PATH, "templates")
