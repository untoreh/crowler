import
  karax / [karaxdsl, vdom, vstyles],
  os,
  strformat,
  xmltree,
  sugar,
  strutils,
  times,
  uri,
  normalize,
  unicode,
  nre,
  json,
  hashes,
  chronos,
  nimpy

import cfg,
       types,
       utils,
       translate,
       translate_misc,
       html_misc,
       html_minify_c,
       amp,
       opg,
       rss,
       ldj,
       shorturls,
       topics,
       quirks, # PySequence requires quirks
  cache,
  articles,
  pyutils,
  ads,
  server_types,
  html_entities

static: echo "loading html..."

const ROOT = initUri() / "/"
const wsPreline = [(white_space, "pre-line")]
const wsBreak = [(white_space, "break-spaces")]

threadVars((preline_style, break_style, VStyle))

proc initHtml*() =
  try:
    preline_style = style(wsPreline)
    break_style = style(wsBreak)
    initZstd()
    initSocial()
  except:
    qdebug "Could not initialize html vars {getCurrentExceptionMsg()}, {getStacktrace()}"

template kxi*(): int = 0
template addEventHandler*(n: VNode; k: EventKind; action: string; kxi: int) =
  n.setAttr($k, action)

proc icon*(name: string; txt = ""; cls = ""): VNode =
  buildHtml(tdiv(class = name)):
    text txt


const mdc_button_classes = "material-icons mdc-top-app-bar__action-item mdc-icon-button"

proc buildButton(button_class: string; custom_classes: string = ""; aria_label: string = "";
        title: string = ""): VNode =
  buildHtml():
    button(class = (&"{mdc_button_classes} {custom_classes}"),
           aria-label = aria_label, title = title):
      tdiv(class = "mdc-icon-button__ripple")
      tdiv(class = button_class)

template ldjWebsite(): VNode {.dirty.} =
  ldj.website(url = $(WEBSITE_URL / topic),
              author = ar.author,
              year = now().year,
              image = LOGO_URL).asVNode

template ldjWebpage(): VNode {.dirty.} =
  let ldjPageProps = newJObject()
  ldjPageProps["author"] = ldj.author(name = ar.author)
  ldjPageProps["availableLanguage"] = %ldjLanguages()
  ldjPageProps["publisher"] = ldj.orgschema(
                      name = ar.url.parseuri().hostname,
                      url = ar.url)
  ldj.webpage(id = canon,
              title = ar.title,
              url = canon,
              mtime = $now(),
              selector = ".post-content",
              description = ar.desc,
              keywords = ar.tags,
              image = ar.imageUrl,
              created = ($ar.pubDate),
              props = ldjPageProps
  ).asVNode

proc buildHead*(path: string; description = ""; topic = "";
    ar = emptyArt): VNode {.gcsafe.} =
  let canon = $(WEBSITE_URL / path)
  buildHtml(head):
    meta(charset = "UTF-8")
    meta(name = "viewport", content = "width=device-width, initial-scale=1")
    link(rel = "canonical", href = canon)
    feedLink(topic, path / topic)
    ampLink(path)
    for t in opgPage(ar): t
    for n in langLinksNodes(canon): n

    # LDJ
    ldjWebsite()
    ldjWebPage()
    breadcrumbs(crumbsNode(ar)).asVNode

    # styles
    # link(rel = "preconnect", href = "https://fonts.googleapis.com")
    # link(rel = "preconnect", href = "https://fonts.gstatic.com", crossorigin = "")
    # link(rel = "stylesheet", href = "https://fonts.googleapis.com/icon?family=Material+Icons")
    # link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=Noto+Serif+Display:ital,wght@0,100;0,300;0,700;1,100;1,300&family=Noto+Serif:ital,wght@0,400;0,700;1,400&family=Petrona:ital,wght@0,400;0,800;1,100;1,400&display=swap")
    link(rel = "stylesheet", href = CSS_REL_URL)
    title:
      text ar.title
    meta(name = "title", content = ar.title)
    meta(name = "keywords", content = ar.tags.join(","))
    meta(name = "description", content = something(description, ar.desc))
    meta(name = "image", content = ar.imageUrl)
    meta(name = "date", content = something($ar.pubDate, $now()))
    link(rel = "icon", href = FAVICON_PNG_URL, type = "image/x-icon")
    link(rel = "icon", href = FAVICON_SVG_URL, type = "image/svg+xml")
    # https://stackoverflow.com/questions/21147149/flash-of-unstyled-content-fouc-in-firefox-only-is-ff-slow-renderer
    verbatim("<script>const _ = null</script>")
    for ad in insertAd(ADS_HEAD): ad


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
        buildButton("i-mdi-twitter", aria_label = "Twitter",
            title = "Twitter share link.")
      a(class = "facebook", href = ("https://www.facebook.com/sharer.php?" & fb_q),
              alt = "Share with Twitter."):
        buildButton("i-mdi-facebook", aria_label = "Facebook",
            title = "Facebook share link.")

proc buildDrawer(a: Article; site: VNode): VNode =
  buildHtml(tdiv(class = "pure-container", data_effect = "pure-effect-slide")):
    input(type = "checkbox", id = "pure-toggle-left", class = "pure-toggle",
            data-toggle = "left")
    label(class = "pure-toggle-label", `for` = "pure-toggle-left",
        data-toggle-label = "left"):
      span(class = "pure-toggle-icon")
    tdiv(class = "pure-drawer", data-position = "left"):
      site
    label(class = "pure-overlay", `for` = "pure-toggle-left",
        data_overlay = "left")

proc buildSearch(action: Uri; withButton = true): VNode =
  buildHtml(form(`method` = "get", action = $(action / "s/"),
      class = "search")):
    label(class = "search-field", `for` = "search-input")
    input(id = "search-input", class = "search-input", autocomplete = "off",
             type = "text", name = "q", placeholder = "Search...")
    ul(class = "search-suggest", style = style([(display, "none")]))
    if withButton:
      buildButton("i-mdi-clear", "clear-search-btn", aria_label = "Clear Search",
              title = "Clear search input.")
      buildButton("i-mdi-search", "search-btn", aria_label = "Search",
              title = "Search across the website.")

proc buildLang(path: string): VNode =
  result = buildButton("i-mdi-translate", "translate menu-lang-btn",
      aria_label = "Languages", title = "Change the language of the website.")
  let langs = buildHtml(tdiv(class = "langs-dropdown-content langs-dropdown-menu")):
    langsList(path)
  result.add langs

proc topicsList*(ucls: string; icls: string; small: static[
    bool] = true): Future[VNode] {.async.} =
  result = newVNode(VNodeKind.ul)
  result.setAttr("class", ucls)
  let topics = await loadTopics(MENU_TOPICS)
  result.add buildHtml(tdiv(class = "topics-shadow"))
  defer: pygil.release()
  await pygil.acquire()
  for tpc in topics:
    let topic_slug = $tpc[0]
    let topic_name = $tpc[1]
    pygil.release()
    if await isEmptyTopic(topic_slug):
      continue
    let liNode = buildHtml(li(class = fmt"{icls}")):
      # tdiv(class = "mdc-icon-button__ripple") # not used without material icons
      a(href = ($(WEBSITE_URL / topic_slug)), title = topic_name,
          class = "mdc-ripple-button"):
        tdiv(class = "mdc-ripple-surface  mdc-ripple-upgraded")
        when small:
          # only use the first letter
          text $topic_name.runeAt(0).toUpper # loadTopics iterator returns pyobjects
        else:
          text topic_name
      when small:
        br()
      else:
        span(class = "separator")
    result.add liNode
    await pygil.acquire()

proc buildMenuSmall*(crumbs: string; topic_uri: Uri; path: string): Future[
    VNode] {.gcsafe, async.} =
  let relpath = $(topic_uri / path)
  return buildHtml():
    section(class = "menu-list mdc-top-app-bar--fixed-adjust"):
    # ul(class = "menu-list mdc-top-app-bar--fixed-adjust"):
      buildButton("i-mdi-brightness-4", "dk-toggle", aria_label = "toggle dark theme",
                  title = "Switch website color between dark and light theme.")
      when TRENDS:
        a(class = "trending", href = ($(topic_uri / "trending"))):
          buildButton("trending_up", aria_label = "Trending",
                  title = "Recent articles that have been trending up.")
      # lang
      buildLang(path)
      # Topics
      await topicsList(ucls = "menu-list-topics", icls = "menu-topic-item")

proc buildMenuSmall*(crumbs: string; topic_uri: Uri; a = emptyArt): Future[
    VNode] {.async.} =
  return await buildMenuSmall(crumbs, topic_uri, a.getArticlePath)

proc buildLogo(pos: string): VNode =
  buildHtml():
    a(class = (pos & " app-bar-logo mdc-icon-button"), href = ($WEBSITE_URL),
            aria-label = "Website Logo"):
      tdiv(class = "mdc-icon-button__ripple")
      span(class = "logo-dark-wrap"):
        img(src = LOGO_DARK_URL)
      span(class = "logo-light-wrap"):
        img(src = LOGO_URL)


proc buildMenu*(crumbs: string; topic_uri: Uri; path: string): Future[
    VNode] {.async.} =
  return buildHtml(header(class = "mdc-top-app-bar menu", id = "app-bar")):
    tdiv(class = "mdc-top-app-bar__row"):
      section(class = "mdc-top-app-bar__section mdc-top-app-bar__section--align-start"):
        # hide the logo on page load
        initStyleStr(".app-bar-logo, .logo-light-wrap {display: none;}")
        # Menu hamburger
        buildButton("i-mdi-menu", "menu-btn", aria_label = "open menu",
                    title = "Menu Drawer")
        buildLogo("left")
        # Dark/light theme toggle
        buildButton("i-mdi-brightness-4", "dk-toggle", aria_label = "toggle dark theme",
                    title = "Switch website color between dark and light theme.")
        # Page location
        a(class = "page mdc-ripple-button mdc-top-app-bar__title",
          title = crumbs,
          href = pathLink(path.parentDir, rel = false)):
          tdiv(class = "mdc-ripple-surface")
          text crumbs
        # Topics list
        await topicsList(ucls = "app-bar-topics", icls = "topic-item", small = false)
      section(class = "mdc-top-app-bar__section mdc-top-app-bar__section--align-end",
              role = "toolbar"):
        buildSearch(topic_uri, true)
        when TRENDS:
          a(class = "trending", href = ($(topic_uri / "trending"))):
            buildButton("trending_up", aria_label = "Trending",
                    title = "Recent articles that have been trending up.")
        # lang
        buildLang(path)
        # logo
        buildLogo("right")

template buildMenu*(crumbs: string; topic_uri: Uri; a: Article): untyped =
  buildMenu(crumbs, topic_uri, a.getArticlePath)

proc buildFooter*(topic: string = ""): Future[VNode] {.async.} =
  return buildHtml(tdiv(class = "site-footer container max border medium no-padding")):
    footer(class = "padding absolute blue white-text primary left bottom"):
      tdiv(class = "footer-links"):
        a(href = ((if topic != "": "/" & topic else: "") & "/sitemap.xml"),
                class = "sitemap"):
          tdiv(class = "icon i-mdi-sitemap")
          text("Sitemap")
        a(href = ((if topic != "": "/" & topic else: "") & "/feed.xml"),
            class = "rss"):
          tdiv(class = "icon i-mdi-rss")
          text("RSS")
        if facebookUrl[] != "":
          a(href = facebookUrl[]):
            tdiv(class = "icon i-mdi-facebook")
            text("Facebook")
        if twitterUrl[] != "":
          a(href = twitterUrl[]):
            tdiv(class = "icon i-mdi-twitter")
            text("Twitter")
        adLink AdLinkType.footer
        a(href = "/dmca"):
          text("DMCA")
        adLink AdLinkType.footer
        a(href = "/privacy-policy"):
          text("Privacy Policy")
        adLink AdLinkType.footer
        a(href = "/terms-of-service"):
          text("Terms of Service")
      for ad in insertAd(ADS_FOOTER): ad
      tdiv(class = "footer-copyright"):
        text "Except where otherwise noted, this website is licensed under a "
        a(rel = "license", href = "http://creativecommons.org/licenses/by/3.0/deed.en_US"):
          text "Creative Commons Attribution 3.0 Unported License."
      script(src = JS_REL_URL, async = "")

proc postTitle(a: Article): Future[VNode] {.async.} =
  return buildHtml(tdiv(class = "title-wrap")):
    h1(class = "post-title", id = "main"):
      a(href = a.slug):
        text a.title
    tdiv(class = "post-info"):
      blockquote(class = "post-desc"):
        text a.desc
      tdiv(class = "post-links"):
        buildSocialShare(a)
        tdiv(class = "post-source"):
          a(href = a.url):
            img(src = a.icon, loading = "lazy", alt = "web",
                class = "material-icons")
            text a.getAuthor
        adLink tags, AdLinkStyle.ico

    buildImgUrl(a)

proc postContent(article: string; withlinks = true): Future[VNode] {.async.} =
  return buildHtml(article(class = "post-wrapper")):
    # NOTE: use `code` tag to avoid minification to collapse whitespace
    pre(class = HTML_POST_SELECTOR, style = break_style):
      verbatim(if withlinks: (await article.replaceLinks) else: article)

proc postFooter(pubdate: Time): VNode =
  let dt = inZone(pubdate, utc())
  buildHtml(tdiv(class = "post-footer")):
    time(datetime = ($dt)):
      text "Published date: "
      italic:
        text format(dt, "dd MMM yyyy")

proc buildBody(a: Article; website_title: string = WEBSITE_TITLE): Future[
    VNode] {.async.} =
  assert not a.isnil
  let crumbs = toUpper(&"/ {a.topic} / Page-{a.page} /")
  let topic_uri = parseUri("/" & a.topic)
  let related = await buildRelated(a)
  return buildHtml(body(class = "", topic = (a.topic), style = preline_style)):
    await buildMenu(crumbs, topic_uri, a)
    await buildMenuSmall(crumbs, topic_uri, a)
    for ad in insertAd(ADS_HEADER): ad
    main(class = "mdc-top-app-bar--fixed-adjust"):
      await postTitle(a)
      await postContent(a.content)
      postFooter(a.pubdate)
      hr()
      related
      for ad in insertAd(ADS_SIDEBAR): ad
    await buildFooter(a.topic)

proc pageTitle*(title: string; slug: string): VNode =
  buildHtml(tdiv(class = "title-wrap")):
    h1(class = "post-title", id = "1"):
      a(href = ($(ROOT / slug))):
        text title

proc pageFooter*(topic: string; pagenum: string; home: bool): Future[
    VNode] {.async.} =
  let
    topic_path = "/" / topic
    pn = if pagenum == "s": -1
             else: pagenum.parseInt
  return buildHtml(tdiv(class = "post-footer")):
    nav(class = "page-crumbs"):
      span(class = "prev-page"):
        if pn > 0:
          a(href = (topic_path / (pn - 1).intToStr)):
            text "<< Previous page"
      # we don't paginate searches because we only serve the first page per query
      if pn != -1 and not home:
        span(class = "next-page"):
          let lpn = await lastPageNum(topic)
          if pn == lpn:
            a:
              text "Next page >>"
          else:
            let nextPageNum = pn + 1
            a(href = (topic_path / (if nextPageNum ==
                    lpn: "" else: nextPageNum.intToStr))):
              text "Next page >>"

const pageContent* = postContent

proc asHtml*(data: auto; minify: static[bool] = true;
    minify_css: bool = true): string =
  let html = "<!DOCTYPE html>"&"\n" & $data
  sdebug "html: raw size {len(html)}"
  result = when minify:
             html.minifyHtml(minify_css = minify_css, minify_js = false)
           else:
             html
  sdebug "html: minified size {len(result)}"

proc writeHtml*(data: auto; path: string) {.inline.} =
  debug "writing html file to {path}"
  let dir = path.parentDir
  if not dir.dirExists:
    try:
      createDir(dir)
    except IOError:
      debug "Could not create directory {dir}, make sure sitepath '{SITE_PATH}' is not a dangling symlink"
  writeFile(path, data.asHtml)


proc processHtml*(relpath: string; slug: string; data: VNode;
    ar = emptyArt): Future[void] {.async.} =
  # outputs (slug, data)
  var o: seq[(string, VNode)]
  let
    path = SITE_PATH
    pagepath = relpath / slug & ".html"
    fpath = path / pagepath
  when cfg.SERVER_MODE:
    pageCache[relpath.fp.hash] = data.asHtml
    # data.writeHtml(SITE_PATH / pagepath)
    return
  when cfg.TRANSLATION_ENABLED and defined(weaveRuntime):
    withWeave(false):
      setupTranslation()
      debug "calling translation with path {fpath} and rx {rx_file.pattern}"
      translateTree(data, fpath, rx_file, langpairs, ar = ar)
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
      yandex.setFeed(ar.topic, ydxTurboFeedpath, topicDesc())
  for (pagepath, page) in o:
    when cfg.AMP:
      ppage = await page.ampPage
    else: ppage = page
    when cfg.YDX:
      turboItem(page, ar)
    when cfg.MINIFY:
      ppage.minifyHtml.writeHtml(fpath)
      when cfg.AMP:
        ppage.minifyHtml.writeHtml(SITE_PATH / "amp" / pagepath)
    else:
      page.writeHtml(SITE_PATH / pagepath)

proc buildPost*(a: Article): Future[VNode] {.async.} =
  let bbody = await buildBody(a)
  return buildHtml(html(lang = DEFAULT_LANG_CODE,
                 prefix = opgPrefix(@[Opg.article, Opg.website]))
  ):
    buildHead(getArticlePath(a), a.desc, a.topic, ar = a)
    bbody

proc buildPage*(title: string; content: VNode; slug: string; pagefooter: VNode = nil; topic = "";
        desc: string = ""): Future[VNode] {.gcsafe, async.} =
  let
    crumbs = if topic != "": fmt"/ {topic.toUpper} /"
             else: "/ "
    topic_uri = parseUri("/" & topic)
    path = topic / slug
  result = buildHtml(html(lang = DEFAULT_LANG_CODE,
                          prefix = opgPrefix(@[Opg.article, Opg.website]))):
    buildHead(path, desc)
    # NOTE: we use the topic attr for the body such that
    # from browser JS we know which topic is the page about
    body(class = "", topic = topic, style = preline_style):
      await buildMenu(crumbs, topic_uri, path)
      await buildMenuSmall(crumbs, topic_uri, path)
      main(class = "mdc-top-app-bar--fixed-adjust"):
        if title != "":
          pageTitle(title, slug)
        content
        if not pagefooter.isNil():
          pageFooter
      await buildFooter(topic)

import macros
macro wrapContent(content: string, wrap: static[bool]): untyped =
  if wrap:
    quote do:
      await pageContent(`content`)
  else:
    quote do:
      verbatim(`content`)

proc emptyVNode(y: static[bool] = true): VNode = newVNode(VNodeKind.verbatim)

proc buildPage*(title, content: string; wrap: static[bool] = false;
       pagefooter = emptyVNode()): Future[VNode] {.async.} =
  let slug = slugify(title)
  return await buildPage(title = title, content.wrapContent(wrap), slug, pagefooter)

proc buildPage*(content: string; wrap: static[bool] = false; pagefooter = emptyVNode()): Future[
    VNode] {.async.} =
  return await buildPage(title = "", content.wrapContent(wrap), slug = "", pagefooter)

proc ldjData*(el: VNode; filepath, relpath: string; lang: langPair; a: Article) =
  ##
  let
    srcurl = pathLink(relpath, rel = false)
    trgurl = pathLink(relpath, code = lang.trg, rel = false)

  let ldjTr = ldjTrans(relpath, srcurl, trgurl, lang, a)


