import karax / [karaxdsl, vdom, vstyles]
import cfg
# import timeit

template kxi(): int = 0
template addEventHandler(n: VNode; k: EventKind; action: string; kxi: int) =
  n.setAttr($k, action)

proc buildHead():VNode =
    buildHtml(head):
        meta(charset="UTF-8")
        meta(name="viewport", content="width=device-width, initial-scale=1")
        title:
            text "hello"
            meta(name="description", content="")
            script(src="")

proc buildSearch():VNode =
    buildHtml(tdiv):
        text "search button"

proc buildLang():VNode =
    buildHtml(tdiv):
        text "lang menu"

proc buildTrending():VNode =
    block: buildHtml(tdiv()):
        text "trending posts"

proc buildMenu():VNode =
    buildHtml(ul(class="menu-list")):
        li(class="search"):
            buildSearch()
        li(class="Trending"):
            buildTrending()
        li(class="language"):
            buildLang()

proc buildContacts():VNode =
    buildHtml(tdiv(class="contacts"))

proc buildFooter():VNode =
    buildHtml(tdiv(class="site-footer")):
        footer():
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


proc postTitle(link=""):VNode =
    buildHtml(tdiv(class="title-wrap")):
        h1(id="title"):
            a(href=link):
                text "post title"
            blockquote(id="page-description")

proc postContent():VNode =
    buildHtml(tdiv(class="post-content")):
        text "post content"

proc postFooter():VNode =
    buildHtml(tdiv(class="post-footer")):
        text "post footer"

proc buildBody(website_title: string = WEBSITE_TITLE): VNode =
    buildHtml(body(class="")):
        tdiv(class="menu-wrap"):
            tdiv(class="menu"):
                a(title=website_title, class="site-title", href="/")
                # here goes logo and contacts / social links
                tdiv(class="logo-wrap"):
                    img(width="64px", height="64px", style=style(StyleAttr.display, "block"))
                nav(id="site-nav"):
                    tdiv(class="horiz")
                    button(type="button", name="Website Menu", class="ham"):
                        italic(class="fas fa-bars ham-icon")
                    tdiv(class="vert")
        postTitle()
        postContent()
        postFooter()
        buildFooter()

proc buildPage():VNode =
    buildHtml(html):
        buildHead()
        buildBody()

when isMainModule:
    echo buildPage()
