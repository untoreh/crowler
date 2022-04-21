import
    karax / [karaxdsl, vdom, vstyles],
    os,
    strformat,
    htmlgen,
    xmlparser,
    xmltree,
    sugar,
    strutils,
    times,
    uri,
    sequtils,
    normalize,
    unicode,
    nre,
    json

import cfg,
       types,
       utils,
       translate,
       translate_misc,
       html_misc,
       html_minify_c,
       amp,
       yandex,
       opg,
       rss,
       ldj

static: echo "loading html..."

const ROOT = initUri() / "/"
const preline = [(white_space, "pre-line")]

threadVars((preline_style, VStyle), (rtime, string), (wsRgx, hypRgx, Regex))

proc initHtml*() =
    try:
        preline_style = style(preline)
        rtime = $now()
        wsRgx = re"[^\w\s-]"
        hypRgx = re"[-\s]+"
    except:
        echo "Could not initialize html vars"

initHtml()

template kxi*(): int = 0
template addEventHandler*(n: VNode; k: EventKind; action: string; kxi: int) =
    n.setAttr($k, action)

const stripchars = ["-".runeAt(0), "_".runeAt(0)]

proc icon*(name: string; txt = ""; cls = ""): VNode =
    buildHtml(span(class = ("mdc-ripple-surface " & cls))):
        italic(class = "material-icons"):
            text name
        text txt

proc slugify*(value: string): string =
    ## Slugifies an unicode string

    result = toNFKC(value).toLower()
    result = result.replace(wsRgx, "")
    result = result.replace(hypRgx, "-").strip(runes = stripchars)

const mdc_button_classes = "material-icons mdc-top-app-bar__action-item mdc-icon-button"

proc buildButton(txt: string; custom_classes: string = ""; aria_label: string = "";
        title: string = ""): VNode =
    buildHtml():
        button(class = (&"{mdc_button_classes} {custom_classes}"),
               aria-label = aria_label, title = title):
            tdiv(class = "mdc-icon-button__ripple")
            text txt

template ldjWebsite(): VNode {.dirty.} =
    ldj.website(url = ($WEBSITE_URL / topic),
                author = ar.author,
                year = now().year,
                image = LOGO_URL).asVNode

template ldjWebpage(): VNode {.dirty.} =
    ldj.webpage(id = canon,
                title = ar.title,
                url = canon,
                mtime = rtime,
                selector = ".post-content",
                description = ar.desc,
                keywords = ar.tags,
                image = ar.imageUrl,
                lang = ar.lang,
                created = ($ar.pubDate),
                props = (%*{
                    "availableLanguage": ldjLanguages(),
                     "author": (ldj.author(name = ar.author)),
                    "publisher": ldj.orgschema(
                        name = WEBSITE_TITLE,
                        url = ($WEBSITE_URL),
                        sameas = WEBSITE_SOCIAL,
                        contact = WEBSITE_CONTACT)
        })
    ).asVNode

proc buildHead*(path: string; description = ""; topic = ""; ar = emptyArt): VNode {.gcsafe.} =
    let canon = $(WEBSITE_URL / path)
    buildHtml(head):
        meta(charset = "UTF-8")
        meta(name = "viewport", content = "width=device-width, initial-scale=1")
        link(rel = "canonical", href = canon)
        feedLink(topic, path)
        ampLink(path)
        for t in opgPage(ar): t
        for n in langLinksNodes(canon): n

        # LDJ
        ldjWebsite()
        ldjWebPage()
        breadcrumbs(crumbsNode(ar)).asVNode

        # styles
        link(rel = "preconnect", href = "https://fonts.googleapis.com")
        link(rel = "preconnect", href = "https://fonts.gstatic.com", crossorigin = "")
        link(rel = "stylesheet", href = "https://fonts.googleapis.com/icon?family=Material+Icons")
        link(rel = "stylesheet", href = CSS_REL_URL)
        title:
            text ar.title
        meta(name = "description", content = description)
        link(rel = "icon", href = FAVICON_PNG_URL, type = "image/x-icon")
        link(rel = "icon", href = FAVICON_SVG_URL, type = "image/svg+xml")

proc buildLang(path: string; title = ""): VNode {.gcsafe.} =
    buildHtml(tdiv(class = "menu-lang-btn", title = "Change website's language")):
        if title != "":
            span:
                text title
        buildButton("translate", "translate", aria_label = "Languages",
                    title = "Change the language of the website."):
            tdiv(class = "langs-dropdown-content langs-dropdown-menu"):
                langsList(path)

proc buildTrending(): VNode =
    block: buildHtml(tdiv()):
        text "trending posts"


proc buildSocialShare(a: Article): VNode =
    # let url = WEBSITE_URL & "/" & a.topic & "/" & a.slug
    let url = $(WEBSITE_URL / a.topic / a.slug)
    let twitter_q = encodeQuery(
        {"text": a.title,
          "hashtags": a.tags.join(","),
          "url": url
            })
    let fb_q = encodeQuery({"u": url,
                 "t": a.title})
    buildHtml:
        tdiv(class = "social-share"):
            a(class = "twitter", href = ("https://twitter.com/share?" & twitter_q & url),
                    alt = "Share with Twitter."):
                buildButton("chat", aria_label = "Twitter", title = "Twitter share link.")
            a(class = "facebook", href = ("https://www.facebook.com/sharer.php?" & fb_q),
                    alt = "Share with Twitter."):
                buildButton("thumb_up", aria_label = "Facebook", title = "Facebook share link.")

proc buildDrawer(a: Article; site: VNode): VNode =
    buildHtml(tdiv(class = "pure-container", data_effect = "pure-effect-slide")):
        input(type = "checkbox", id = "pure-toggle-left", class = "pure-toggle",
                data-toggle = "left")
        label(class = "pure-toggle-label", `for` = "pure-toggle-left", data-toggle-label = "left"):
            span(class = "pure-toggle-icon")
        tdiv(class = "pure-drawer", data-position = "left"):
            site
        label(class = "pure-overlay", `for` = "pure-toggle-left", data_overlay = "left")

proc buildImgUrl*(url: string; cls = "image-link"): VNode =
    let cache_url = "/img/" & encodeUrl(url)
    buildHtml(a(class = cls, href = url, alt = "post image source")):
        # the `alt="image"` is used to display the material-icons placeholder
        img(class = "material-icons", src = cache_url, alt = "image", loading = "lazy")


proc buildSearch(withButton = true): VNode =
    buildHtml(tdiv(class = "search-bar")):
        label(class = "search-field"):
            input(class = "search-input", type = "text", placeholder = "Search...")
        if withButton:
            buildButton("search", "search-btn", aria_label = "Search",
                    title = "Search across the website.")

proc buildMenuSmall*(crumbs: string; topic_uri: Uri; path: string): VNode {.gcsafe.} =
    let relpath = $(topic_uri / path)
    buildHtml():
        section(class = "menu-list mdc-top-app-bar--fixed-adjust"):
        # ul(class = "menu-list mdc-top-app-bar--fixed-adjust"):
            buildButton("brightness_4", "dk-toggle", aria_label = "toggle dark theme",
                        title = "Switch website color between dark and light theme.")
            a(class = "trending", href = ($(topic_uri / "trending"))):
                buildButton("trending_up", aria_label = "Trending",
                        title = "Recent articles that have been trending up.")
            buildLang(path)
proc buildMenuSmall*(crumbs: string; topic_uri: Uri; a = emptyArt): VNode =
    buildMenuSmall(crumbs, topic_uri, a.getArticleUrl)

proc buildLogo(pos: string): VNode =
    buildHtml():
        a(class = (pos & " app-bar-logo mdc-icon-button"), href = ($WEBSITE_URL),
                aria-label = "Website Logo"):
            tdiv(class = "mdc-icon-button__ripple")
            span(class = "logo-dark-wrap"):
                img(src=LOGO_DARK_URL)
            span(class = "logo-light-wrap"):
                img(src=LOGO_URL)


proc buildMenu*(crumbs: string; topic_uri: Uri; path: string): VNode =
    buildHtml(header(class = "mdc-top-app-bar menu", id = "app-bar")):
        tdiv(class = "mdc-top-app-bar__row"):
            section(class = "mdc-top-app-bar__section mdc-top-app-bar__section--align-start"):
                # hide the logo on page load
                initStyleStr(".app-bar-logo, .logo-light-wrap {display: none;}")
                buildButton("menu", "menu-btn", aria_label = "open menu",
                            title = "Menu Drawer")
                buildLogo("left")
                buildButton("brightness_4", "dk-toggle", aria_label = "toggle dark theme",
                            title = "Switch website color between dark and light theme.")
                a(class = "page mdc-top-app-bar__title mdc-ripple-surface",
                  href = pathLink(path.parentDir, rel = false)):
                    text crumbs
            section(class = "mdc-top-app-bar__section mdc-top-app-bar__section--align-end",
                    role = "toolbar"):
                buildSearch(false)
                buildButton("search", "search-btn", aria_label = "Search",
                        title = "Search across the website.")
                a(class = "trending", href = ($(topic_uri / "trending"))):
                    buildButton("trending_up", aria_label = "Trending",
                            title = "Recent articles that have been trending up.")
                buildLang(path)
                buildLogo("right")

template buildMenu*(crumbs: string; topic_uri: Uri; a: Article): untyped =
    buildMenu(crumbs, topic_uri, a.getArticlePath)

proc buildFooter*(): VNode =
    buildHtml(tdiv(class = "site-footer container max border medium no-padding")):
        footer(class = "padding absolute blue white-text primary left bottom"):
            tdiv(class = "footer-links"):
                a(href = "/sitemap.xml"):
                    text("Sitemap")
                text " - "
                a(href = "/feed.xml"):
                    text("RSS")
                text " - "
                a(href = "/dmca.html"):
                    text("DMCA")
                text " - "
                a(href = "/privacy-policy.html"):
                    text("Privacy Policy")
            tdiv(class = "footer-copyright"):
                text "Except where otherwise noted, this website is licensed under a "
                a(rel = "license", href = "http://creativecommons.org/licenses/by/3.0/deed.en_US"):
                    text "Creative Commons Attribution 3.0 Unported License."
            script(src = JS_REL_URL , async = "")

proc postTitle(a: Article): VNode =
    buildHtml(tdiv(class = "title-wrap")):
        h1(class = "post-title", id = "main"):
            a(href = a.slug):
                text a.title
        tdiv(class = "post-info"):
            blockquote(class = "post-desc"):
                text a.desc
            buildSocialShare(a)
            tdiv(class = "post-source"):
                a(href = a.url):
                    img(src = a.icon, loading = "lazy", alt = "web", class = "material-icons")
                    text a.getAuthor
        buildImgUrl(a.imageUrl)

proc postContent(article: string): VNode =
    buildHtml(article(class = "post-wrapper")):
        tdiv(class = "post-content"):
            verbatim(article)

proc postFooter(pubdate: Time): VNode =
    let dt = inZone(pubdate, utc())
    buildHtml(tdiv(class = "post-footer")):
        time(datetime = ($dt)):
            text "Published date: "
            italic:
                text format(dt, "dd MMM yyyy")

proc buildBody(a: Article; website_title: string = WEBSITE_TITLE): VNode =
    let crumbs = toUpper(&"/ {a.topic} / Page-{a.page} >")
    let topic_uri = parseUri("/" & a.topic)
    buildHtml(body(class = "", style = preline_style)):
        buildMenu(crumbs, topic_uri, a)
        buildMenuSmall(crumbs, topic_uri, a)
        main(class = "mdc-top-app-bar--fixed-adjust"):
            postTitle(a)
            postContent(a.content)
            postFooter(a.pubdate)
        buildFooter()

proc pageTitle*(title: string; slug: string): VNode =
    buildHtml(tdiv(class = "title-wrap")):
        h1(class = "post-title", id = "1"):
            a(href = ($(ROOT / slug))):
                text title

proc pageFooter*(topic: string; pagenum: string; home: bool): VNode =
    let
        topic_path = "/" / topic
        pn = pagenum.parseInt
    buildHtml(tdiv(class = "post-footer")):
        nav(class = "page-crumbs"):
            if pn > 0:
                span(class = "prev-page"):
                    a(href = (topic_path / (pn - 1).intToStr)):
                        text "<< Previous page"
            if not home:
                span(class = "next-page"):
                    a(href = (topic_path / (pn + 1).intToStr)):
                        text "Next page >>"

const pageContent* = postContent

proc asHtml*(data: auto): string {.inline.} = fmt"<!doctype html>{'\n'}{data}"

proc writeHtml*(data: auto; path: string) {.inline.} =
    debug "writing html file to {path}"
    let dir = path.parentDir
    if not dir.existsDir:
        createDir(dir)
    writeFile(path, data.asHtml)


proc processHtml*(relpath: string; slug: string; data: VNode; ar = emptyArt) =
    # outputs (slug, data)
    var o: seq[(string, VNode)]
    let
        path = SITE_PATH
        pagepath = relpath / slug & ".html"
        fullpath = path / pagepath
    when cfg.TRANSLATION_ENABLED:
        withWeave(false):
            setupTranslation()
            debug "calling translation with path {fullpath} and rx {rx_file.pattern}"
            translateTree(data, fullpath, rx_file, langpairs, ar = ar)
        for (code, n) in trOut:
            o.add (code / pagepath, n)
        trOut.clear()
        o.add (SLang.code / pagepath, data)
    else:
        o.add (pagepath, data)
    # Search goes here
    #
    # NOTE: after the amp process we copy the page HTML because
    # amp uses a global tree
    var ppage: VNode
    when cfg.YDX:
        if yandex.feedTopic != ar.topic:
            let ydxTurboFeedpath = $(WEBSITE_URL / topic / "ydx.xml")
            yandex.setFeed(ar.topic, ydxTurboFeedpath, topicDesc(), ar.lang)
    for (pagepath, page) in o:
        when cfg.AMP:
            ppage = page.ampPage
        else: ppage = page
        when cfg.YDX:
            turboItem(page, ar)
        when cfg.MINIFY:
            ppage.minifyHtml.writeHtml(fullpath)
            when cfg.AMP:
                ppage.minifyHtml.writeHtml(SITE_PATH / "amp" / pagepath)
        else:
            page.writeHtml(SITE_PATH / pagepath)

proc buildPost*(a: Article): VNode =
    buildHtml(html(lang = DEFAULT_LANG_CODE,
                   prefix = opgPrefix(@[Opg.article, Opg.website]))
    ):
        buildHead(getArticlePath(a), a.desc, a.topic)
        buildBody(a)

proc buildPage*(title: string; content: string; slug: string; pagefooter: VNode = nil; topic = "";
        desc: string = ""): VNode {.gcsafe.} =
    let
        crumbs = if topic != "": fmt"/ {topic} >"
                 else: "/ "
        topic_uri = parseUri("/ >")
        path = topic / slug
    result = buildHtml(html(lang = DEFAULT_LANG_CODE,
                            prefix = opgPrefix(@[Opg.article, Opg.website]))):
        buildHead(path, desc)
        body(class = "", style = preline_style):
            buildMenu(crumbs, topic_uri, path)
            buildMenuSmall(crumbs, topic_uri)
            main(class = "mdc-top-app-bar--fixed-adjust"):
                if title != "":
                    pageTitle(title, slug)
                pageContent(content)
                if not pagefooter.isNil():
                    pageFooter
            buildFooter()

proc buildPage*(title: string; content: string; pagefooter: VNode = static(VNode())): VNode =
    let slug = slugify(title)
    buildPage(title = title, content, slug, pagefooter)

proc buildPage*(content: string; pagefooter: VNode = static(VNode())): VNode =
    buildPage(title = "", content, slug = "", pagefooter)

proc ldjData*(el: VNode; filepath, relpath: string; lang: langPair; a: Article) =
    ##
    let
        srcurl = pathLink(relpath, rel = false)
        trgurl = pathLink(relpath, code = lang.trg, rel = false)

    let ldjTr = ldjTrans(relpath, srcurl, trgurl, lang, a)
