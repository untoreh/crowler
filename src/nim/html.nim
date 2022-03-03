import karax / [karaxdsl, vdom, vstyles]
import cfg
import os
import strformat
import macros
# import timeit
import htmlgen
import xmlparser
import xmltree
import sugar
import strutils
import types
import times
import uri
import sequtils

const LOGO_HTML = readFile(LOGO_PATH)
const LOGO_SMALL_HTML = readFile(LOGO_SMALL_PATH)
const LOGO_ICON_HTML = readFile(LOGO_ICON_PATH)
const LOGO_DARK_HTML = readFile(LOGO_DARK_PATH)
const LOGO_DARK_SMALL_HTML = readFile(LOGO_DARK_SMALL_PATH)
const LOGO_DARK_ICON_HTML = readFile(LOGO_DARK_ICON_PATH)

template kxi(): int = 0
template addEventHandler(n: VNode; k: EventKind; action: string; kxi: int) =
  n.setAttr($k, action)

proc buildHead():VNode =
    buildHtml(head):
        meta(charset="UTF-8")
        meta(name="viewport", content="width=device-width, initial-scale=1")
        link(rel="preconnect", href="https://fonts.googleapis.com")
        link(rel="preconnect", href="https://fonts.gstatic.com", crossorigin="")
        link(rel="stylesheet", href="https://fonts.googleapis.com/icon?family=Material+Icons")
        link(rel="stylesheet", href="/bundle.css")
        # link(rel="stylesheet", href="src/css/main.css")
        title:
            text "hello"
        meta(name="description", content="")
        # script(src="https://cdn.jsdelivr.net/npm/beercss@2.0.10/dist/cdn/beer.min.js", type="text/javascript")

proc buildSearch():VNode =
    buildHtml(tdiv):
        text "search button"

proc buildLang():VNode =
    buildHtml(tdiv):
        text "lang menu"

proc buildTrending():VNode =
    block: buildHtml(tdiv()):
        text "trending posts"

const mdc_button_classes="material-icons mdc-top-app-bar__action-item mdc-icon-button"

proc buildButton(txt: string, custom_classes: string="", aria_label: string ="", title: string =""):VNode =
    buildHtml():
        button(class=(&"{mdc_button_classes} {custom_classes}"),
               aria-label=aria_label, title=title):
            tdiv(class="mdc-icon-button__ripple")
            text txt

proc buildSocialShare(a: Article):VNode =
    # let url = WEBSITE_URL & "/" & a.topic & "/" & a.slug
    let url = $(WEBSITE_URL / a.topic / a.slug)
    let twitter_q = encodeQuery(
        {"text": a.title,
          "hashtags" : a.tags.join(","),
          "url": url
          })
    var fb_q = encodeQuery({"u": url,
                 "t": a.title})
    buildHtml:
        tdiv(class="social-share"):
                a(class="twitter", href=("https://twitter.com/share?" & twitter_q & url), alt="Share with Twitter."):
                    buildButton("chat", aria_label="Twitter", title="Twitter share link.")
                a(class="facebook", href=("https://www.facebook.com/sharer.php?" & fb_q), alt="Share with Twitter."):
                    buildButton("thumb_up", aria_label="Facebook", title="Facebook share link.")


proc buildMenu(crumbs: string): VNode =
    buildHtml(header(class="mdc-top-app-bar menu")):
        tdiv(class="mdc-top-app-bar__row"):
            section(class="mdc-top-app-bar__section mdc-top-app-bar__section--align-start"):
                a(class="app-bar-logo mdc-icon-button", href=($WEBSITE_URL), aria-label="Website Logo"):
                    tdiv(class="mdc-icon-button__ripple")
                    span(class="logo-light-wrap"):
                        verbatim(LOGO_HTML)
                    span(class="logo-dark-wrap"):
                        verbatim(LOGO_DARK_HTML)
                    span(class="logo-light-icon-wrap"):
                        verbatim(LOGO_ICON_HTML)
                    span(class="logo-dark-icon-wrap"):
                        verbatim(LOGO_DARK_ICON_HTML)
                buildButton("brightness_4", "dk-toggle", aria_label="toggle dark theme",
                            title="Switch website color between dark and light theme.")
                a(class="page mdc-top-app-bar__title mdc-ripple-surface", href="/"):
                    text crumbs
            section(class="mdc-top-app-bar__section mdc-top-app-bar__section--align-end", role="toolbar"):
                label(class="mdc-text-field mdc-text-field--filled"):
                    span(class="mdc-text-field__ripple")
                    span(class="mdc-floating-label", id="search-label"):
                        text "Search"
                    input(class="mdc-text-field__input", type="text", aria-labelledby="search-label")
                    span(class="mdc-line-ripple")
                buildButton("search", aria_label="Search", title="Search across the website.")
                a(href="/trending"):
                    buildButton("trending_up", aria_label="Trending", title="Recent articles that have been trending up.")
                buildButton("translate", aria_label="Languages", title="Change the language of the website.")

proc buildFooter():VNode =
    buildHtml(tdiv(class="site-footer container max border medium no-padding")):
        footer(class="padding absolute blue white-text primary left bottom"):
            tdiv(class="footer-links"):
                a(href="/sitemap.xml"):
                    text("Sitemap")
                text " - "
                a(href="/feed.xml"):
                    text("RSS")
            tdiv(class="footer-copyright"):
                text "Except where otherwise noted, this website is licensed under a "
                a(rel="license", href="http://creativecommons.org/licenses/by/3.0/deed.en_US"):
                    text "Creative Commons Attribution 3.0 Unported License."
            script(src="/bundle.js", async="")

proc buildImgUrl(url: string): VNode =
    let cache_url = "/img/" & encodeUrl(url)
    buildHtml(a(class="image-link", href=url, alt="post image source")):
        img(class="material-icons", src=cache_url, alt="image", loading="lazy")

proc postTitle(a: Article):VNode =
    buildHtml(tdiv(class="title-wrap")):
        h1(id="title"):
            a(href=a.slug):
                text a.title
        tdiv(class="post-info"):
            blockquote(class="post-desc"):
                text a.desc
            buildSocialShare(a)
            tdiv(class="post-source"):
                a(href=a.url):
                    img(src=a.icon, loading="lazy")
                    text $a.author
        buildImgUrl(a.imageUrl)

proc postContent(article: string):VNode =
    buildHtml(article(class="post-wrapper container max")):
        tdiv(class="post-content"):
            text article

proc postFooter(pubdate: Time):VNode =
    let dt = inZone(pubdate, utc())
    buildHtml(tdiv(class="post-footer")):
        time(datetime=($dt)):
            text "Published date: "
            italic:
                text format(dt, "dd MMM yyyy")


proc buildBody(a: Article, website_title: string = WEBSITE_TITLE): VNode =
    let crumbs = toUpper(&"/ {a.topic} > ...")
    buildHtml(body(class="")):
        tdiv(class="menu-wrap"):
            buildMenu(crumbs)
        main(class="mdc-top-app-bar--fixed-adjust"):
            postTitle(a)
            postContent(a.content)
            postFooter(a.pubdate)
        buildFooter()

proc buildPage*(basedir: string, a: Article) =
    let page = buildHtml(html):
        buildHead()
        buildBody(a)
    let path = basedir / a.slug & ".html"
    writeFile(path, &("<!doctype html>\n{page}"))

when isMainModule:
    var path = joinPath(SITE_PATH, "index.html")
