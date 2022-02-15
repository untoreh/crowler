import karax / [karaxdsl, vdom, vstyles]
import cfg
import os
import strformat
# import timeit

template kxi(): int = 0
template addEventHandler(n: VNode; k: EventKind; action: string; kxi: int) =
  n.setAttr($k, action)

proc buildHead():VNode =
    buildHtml(head):
        meta(charset="UTF-8")
        meta(name="viewport", content="width=device-width, initial-scale=1")
        link(rel="stylesheet", href="bundle.css")
        link(rel="stylesheet", href="https://fonts.googleapis.com/icon?family=Material+Icons")
        # link(rel="stylesheet", href="src/css/main.css")
        # link(rel="stylesheet", href="https://cdn.jsdelivr.net/npm/beercss@2.0.10/dist/cdn/beer.min.css")
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

# proc logo():VNode =
#     buildHtml

proc buildMenu():VNode =
    buildHtml(header(class="mdc-top-app-bar ")):
        tdiv(class="mdc-top-app-bar__row"):
            section(class="mdc-top-app-bar__section mdc-top-app-bar__section--align-start"):
                button(class="material-icons mdc-top-app-bar__navigation-icon mdc-icon-button", aria-label="Open navigation menu"):
                    text "menu"
                span(class="mdc-top-app-bar__title"):
                    text "Page title"
            section(class="mdc-top-app-bar__section mdc-top-app-bar__section--align-end", role="toolbar"):
                button(class="material-icons mdc-top-app-bar__action-item mdc-icon-button", aria-label="Search"):
                    text "search"
                button(class="material-icons mdc-top-app-bar__action-item mdc-icon-button", aria-label="Trending"):
                    text "trending"
                button(class="material-icons mdc-top-app-bar__action-item mdc-icon-button", aria-label="Languages"):
                    text "langs"
        # ul(class="menu-list"):
        #     li(class="search"):
        #         buildSearch()
        #     li(class="Trending"):
        #         buildTrending()
        #     li(class="language"):
        #         buildLang()

proc buildContacts():VNode =
    buildHtml(tdiv(class="contacts"))

proc buildFooter():VNode =
    buildHtml(tdiv(class="site-footer container max border medium no-padding")):
        footer(class="padding absolute blue white-text primary left bottom"):
            tdiv(class="footer-copyright"):
                text("footer copyright")
            tdiv(class="footer-links"):
                ul():
                    li():
                        a(href="/sitemap.xml"):
                            text("Sitemap")
                    li():
                        a(href="/trends"):
                            text("Trends")
                    li():
                        a(href="/feed.xml"):
                            text("RSS")
            tdiv(class="footer-author-wrap"):
                ul(class="footer-author"):
                    buildContacts()
            script(src="bundle.js", async="")


proc postTitle(link=""):VNode =
    buildHtml(tdiv(class="title-wrap")):
        h1(id="title"):
            a(href=link):
                text "post title"
            blockquote(id="page-description")

proc postContent():VNode =
    buildHtml(article(class="post-wrapper container max")):
        h3(class="post-title")
        tdiv(class="post-content"):
            text "post content"

proc postFooter():VNode =
    buildHtml(tdiv(class="post-footer")):
        text "post footer"

proc buildBody(website_title: string = WEBSITE_TITLE): VNode =
    buildHtml(body(class="mdc-layout-grid")):
        tdiv(class="menu-wrap"):
            buildMenu()
        main(class="mdc-top-app-bar--fixed-adjust"):
            text "app content"
            # tdiv(class="menu m 1 top"):
            #     a(title=website_title, class="site-title", href="/")
            #     # here goes logo and contacts / social links
            #     tdiv(class="logo-wrap"):
            #         img(width="64px", height="64px", style=style(StyleAttr.display, "block"))
            #     nav(id="site-nav"):
            #         tdiv(class="horiz")
            #         button(type="button", name="Website Menu", class="ham mdc-button"):
            #             tdiv(class="mdc-button__ripple")
            #             span(class="mdc-button__label"):
            #                 text "menu button"
            #             # italic(class="fas fa-bars ham-icon")
            #         tdiv(class="vert")
        tdiv(class="mdc-layout-grid__cell"):
            tdiv(class="mdc-layout-grid__inner"):
                tdiv(class="mdc-layout-grid__cell"):
                    postTitle()
                tdiv(class="mdc-layout-grid__cell"):
                    postContent()
                tdiv(class="mdc-layout-grid__cell"):
                    postFooter()
        tdiv(class="mdc-layout-grid__cell"):
            buildFooter()

proc buildPage():VNode =
    buildHtml(html):
        buildHead()
        buildBody()

when isMainModule:
    var path = expandfilename(&".{DirSep}..{DirSep}..{DirSep}site")
    path.add(&"{DirSep}index.html")
    writeFile(path, &("<!doctype html>\n{buildPage()}"))
