import html
import cfg
import karax / [karaxdsl, vdom, vstyles]
import strutils
import os
import uri

const tplRep = @{ "WEBSITE_DOMAIN": WEBSITE_DOMAIN }
const ppRep = @{"WEBSITE_URL": $WEBSITE_URL.combine(),
                 "WEBSITE_DOMAIN" : WEBSITE_DOMAIN}

proc buildPageFromTemplate(tpl: string, title: string, vars: seq[(string, string)] = tplRep) =
    var txt = readfile(ASSETS_PATH / "templates"/ tpl)
    txt = multiReplace(txt, vars)
    buildPage(SITE_PATH, title, txt)

proc buildInfoPages() =
    ## Build DMCA, TOS, and GPDR pages
    buildPageFromTemplate("dmca.html", "DMCA")
    buildPageFromTemplate("tos.html", "Terms of Service")
    buildPageFromTemplate("privacy-policy.html", "Privacy Policy", ppRep)

proc buildHomePage() =
    buildPage(SITE_PATH, content="")


when isMainModule:
    buildHomePage()
