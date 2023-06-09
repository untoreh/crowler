{.push hint[DuplicateModuleImport]: off.}
import
  karax / [karaxdsl, vstyles],
  uri,
  sequtils,
  unicode,
  xmltree,
  algorithm,
  chronos,
  htmlparser,
  lrucache

import html_misc,
       translate,
       translate_lang,
       amp,
       search,
       ads,
       server_types

var
  tplRep {.threadvar.}: seq[(string, string)]
  ppRep {.threadvar.}: seq[(string, string)]

proc initPages*() =
  tplRep.add @{"WEBSITE_DOMAIN": config.websiteDomain}
  ppRep.add @{"WEBSITE_URL": $config.websiteUrl.combine(),
                 "WEBSITE_DOMAIN": config.websiteDomain}

proc getSubDirs(path: string): seq[int] =
  var dirs = collect((for f in walkDirs(path / "*"):
    try: parseInt(lastPathPart(f)) except: -1))
  sort(dirs, Descending)
  dirs

proc countDirFiles(path: string): int =
  len(collect(for f in walkFiles(path / "*"): f))

proc ensureHome(topic: string, pagenum: int) =
  ## Make sure the homepage links to the last page directory
  let
    topic_path = SITE_PATH / topic
    # homepage default dir
    page_path = topic_path / $pagenum
    # homepage index file
    home_index = page_path / "index.html"
    # the homepage index file should like to root topic dir
    target_home_link = topic_path / "index.html"
  createDir(page_path)
  # make sure the symlink points correctly
  if symlinkExists(target_home_link):
    # we should serve something
    if not fileExists(home_index):
      writeFile(home_index, "")
    if not fileExists(target_home_link) or
       not sameFile(home_index, target_home_link):
      removeFile(target_home_link)
      createSymlink(home_index, target_home_link)
  else:
    createSymlink(home_index, target_home_link)

proc getSubdirNumber(topic: string, iter: int = -1): (int, bool) =
  let topic_path = SITE_PATH / topic
  var topdir: int
  if iter < 0:
    # we are only interested in the highest numbered directory
    let dirs = getSubDirs(topic_path)
    if len(dirs) == 0:
      ensureHome(topic, 0)
      return (0, true)
    topdir = dirs.high
  else:
    topdir = iter
  # NOTE: we don't consider how many articles are in a batch
  # so this is a soft limit
  if countDirFiles(topic_path / $topdir) < MAX_DIR_FILES:
    return (topdir, false)
  (topdir + 1, true)

proc getLastTopicDir*(topic: string): string =
  let dirs = getSubDirs(SITE_PATH / topic)
  return $max(1, dirs.high)


proc pageArticles*(topic: string; pagenum: string): seq[string] =
  let dir = SITE_PATH / topic / pagenum
  collect:
    for p in walkFiles(dir / "*.html"):
      if lastPathPart(p) != "index.html": p

proc pageArticles*(topic: string): seq[string] =
  pageArticles(topic, getLastTopicDir(topic))

proc pageArticles*(topic: string; pagenum: int): seq[string] =
  pageArticles(topic, $pagenum)

proc articleExcerpt(a: Article): string =
  let alen = len(a.content) - 1
  let maxlen = min(alen, config.articleExcerptSize)
  if maxlen == alen:
    return a.content
  else:
    let runesize = runeLenAt(a.content, maxlen)
    # If article contains html tags, the excerpt might have broken html
    return parseHtml(a.content[0..maxlen+runesize]).innerText & "..."

import htmlparser
proc articleEntry(ar: Article, topic = ""): Future[VNode] {.async.} =
  if ar.topic == "" and topic != "":
    ar.topic = topic
  let relpath = getArticlePath(ar)
  try:
    return buildHtml(article(class = "entry")):
      buildImgUrl(ar, defsrc = $config.defaultImageUrl)
      h2(class = "entry-title", id = ar.slug):
        a(href = relpath):
          text ar.title
      tdiv(class = "entry-info"):
        span(class = "entry-author"):
          text ar.getAuthor & ", "
        time(class = "entry-date", datetime = ($ar.pubDate)):
          italic:
            text format(ar.pubDate, "dd/MMM")
      tdiv(class = "entry-tags"):
        if ar.tags.len == 0:
          span(class = "entry-tag-name"):
            a(href = (await nextAdsLink()), target = "_blank"):
              icon("i-mdi-tag")
              text "none"
        else:
          for t in ar.tags:
            if likely(t.isSomething):
              span(class = "entry-tag-name"):
                a(href = (await nextAdsLink()), target = "_blank"):
                  icon("i-mdi-tag")
                  text t
      # tdiv(class = "entry-content"):
      #   verbatim(articleExcerpt(ar))
      #   a(class = "entry-more", href = relpath):
      #     text "[continue]"
  except Exception as e:
    logexc()
    warn "articles: entry creation failed."
    raise e

proc buildShortPosts*(arts: seq[Article], topic = "", lang = ""): Future[
    string] {.async.} =
  var sepAds = adsGen(adsSeparator)
  var sepLinks = adsGen(adsSeparator)
  let hr = buildHtml(hr())

  for a in arts:
    result.add $(await articleEntry(a, topic))
    result.add hr
    let ads = buildHtml(tdiv(class = "sep-ads"))
    let sep1 = filterNext(sepAds, notEmpty)
    if not sep1.isnil:
      ads.add sep1
    let sep2 = sepLinks.filterNext(notEmpty)
    if not sep2.isnil:
      ads.add sep2
    result.add ads

template topicPage*(name: string, pn: string, istop = false,
    lng = "") {.dirty.} =
  ## Writes a single page (fetching its related articles, if its not a template) to storage
  let pnInt = pn.parseInt
  let arts =
    if istop: await getLastArticles(name, cfg.HOME_ARTS)
    else: await getDoneArticles(name, pagenum = pnInt)
  debug "topics: name page for page {pnInt} ({len(arts)})"
  let content = await buildShortPosts(arts, name, lng)
  # if the page is not finalized, it is the homepage
  let footer = await pageFooter(name, pn, home = istop)
  let pagetree =
    await buildPage(
      title = "", # this is NOT a `title` tag
      content = verbatim(content),
      slug = (if istop: "" else: pn),
      pagefooter = footer,
      lang = lng,
      topic = name
      )

{.experimental: "notnil".}
proc transId(lang, relpath: string): string = SLang.code & lang & relpath

{.push gcsafe.}
proc processPage*(lang, amp: string, tree: VNode not nil,
    relpath = "index"): Future[VNode] {.async.} =
  if lang in TLangsCodes:
    let
      filedir = SITE_PATH
      tpath = filedir / lang / relpath
    var fc = init(FileContext, tree, filedir, relpath,
          (src: SLang.code, trg: lang), tpath, config)
    debug "page: translating page to {lang}"
    let jobId = transId(lang, relpath)
    result = await translateLang(move fc,
        timeout = TRANSLATION_WAITTIME, jobId = jobId)
  else:
    result = tree
  checkNil(result, "page: tree cannot be nil")
  if amp != "":
    result = await result.ampPage

proc processTranslatedPage*(lang: string, amp: string, relpath: string): Future[
    VNode] {.async.} =
  let jobId = transId(lang, relpath)
  if jobId notin translateFuts:
    raise newException(ValueError, fmt"Translation was not scheduled. (transId: {jobId})")
  let (node, fut) = translateFuts[jobId]
  defer:
    # NOTE: this must be done after completion since other request might
    # happen at the same time on this page
    if jobId in translateFuts:
      translateFuts.del(jobId)
  discard await fut
  # signal that full translation is complete to js
  node.find(VNodeKind.meta, ("name", "translation")).setAttr("content", "complete")
  result =
    if amp != "": await node.ampPage
    else: node

proc pageFromTemplate*(tpl, lang, amp: string): Future[string] {.async.} =
  var txt = await readfileAsync(config.assetsPath / "templates" / tpl & ".html")
  let domain = config.websiteDomain
  let (vars, title, desc) =
    case tpl:
      of "dmca": (tplRep, "DMCA", fmt"dmca compliance for {domain}")
      of "tos": (ppRep, "Terms of Service",
                 fmt"Terms of Service for {domain}")
      of "privacy-policy": (ppRep, "Privacy Policy",
                            fmt"Privacy Policy for {domain}")
      else: (tplRep, tpl, "")
  txt = multiReplace(txt, vars)
  let
    slug = slugify(title)
    page = await buildPage(title = title, content = txt, lang = lang,
                            desc = desc, topic = "", wrap = true)
  checkNil(page):
    let processed = await processPage(lang, amp, page, relpath = tpl)
    checkNil(processed, fmt"failed to process template {tpl}, {lang}, {amp}"):
      return processed.asHtml(minify_css = (amp == ""))

proc articleTree*(capts: auto): Future[VNode] {.async.} =
  # every article is under a page number
  let py = await getArticlePy(capts.topic, capts.page, capts.art)
  var a: Article
  withPyLock:
    if not pyisnone(py):
      debug "article: building post"
      a = initArticle(py, parseInt(capts.page))
  if not a.isnil:
    let post = await buildPost(a, capts.lang)
    if not post.isnil:
      debug "article: processing"
      let path = join([capts.topic, capts.page, capts.art], "/")
      return await processPage(capts.lang, capts.amp, post, relpath = path)
  debug "article: could not fetch python article."

proc articleHtml*(capts: auto): Future[string] {.gcsafe, async.} =
  let t = await articleTree(capts)
  return if not t.isnil:
               t.asHtml(minify_css = (capts.amp == ""))
           else: ""

template divWrap(class = "", cnt: string): string =
  var res: string
  res.add "<div class=\"" & class & "\">"
  res.add cnt
  res.add "</div>"
  res

proc buildHomePage*(lang, amp: string): Future[VNode] {.async.} =
  var
    a: Article
    content: string
  withPyLock:
    a = default(Article)
  try:
    var
      nTopics = len(topicsCache)
      batchSize = cfg.HOME_ARTS.div(nTopics) + 1
      counters = initTable[string, int](nTopics)
      nArts = 0
      processed: HashSet[string]
      trial = 0
      maxTries = cfg.HOME_ARTS * 3
      sepAds = adsGen(adsSeparator)
      sepLinks = adsGen(adsSeparator)

    while nArts < cfg.HOME_ARTS and trial < maxTries:
      trial.inc
      var topic: string
      withPyLock:
        topic = site.get_random_topic().to(string)
      if topic == "": # this can happen if we ran out of topics
        continue
      let arts = await getLastArticles(topic, batchSize)
      if len(arts) > 0:
        if topic notin counters:
          counters[topic] = -1
        counters[topic].inc
        for n in counters[topic]..<len(arts):
          let ar = arts[n]
          if ar.slug notin processed:
            content.add $(await articleEntry(ar))
            let link = sepLinks.filterNext(notEmpty)
            if not link.isnil:
              content.add buildHtml(tdiv(class = "ads-sep"), link)
            processed.incl ar.slug
            nArts.inc
  except:
    logexc()

  let pagetree = await buildPage(title = "",
                       content = verbatim(content),
                       slug = "",
                       lang = lang,
                       topic = "",
                       desc = config.websiteDescription)
  checkNil(pagetree):
    return await processPage(lang, amp, pagetree)

proc buildSearchPage*(topic: string, kws: string, lang: string,
    capts: UriCaptures): Future[string] {.async.} =
  ## Builds a search page with 10 entries
  debug "search: lang:{lang}, topic:{topic}, kws:{kws}"
  var content, keywords: string
  var sepAds = adsGen(adsSeparator)
  if kws != "":
    keywords = kws.decodeUrl.sanitize
    var pslugs = await query(topic, keywords, lang)
    if pslugs.len == 0:
      let r = buildHtml(tdiv(class = "search-results")):
        text "No results found."
      content.add $r
    else:
      if pslugs[0] == "/":
        del(pslugs, 0)
      for pslug in pslugs:
        let ar = await fromSearchResult(pslug)
        if not ar.isEmpty:
          let ads = buildHtml(tdiv(class = "sep-ads"))
          let sep1 = filterNext(sepAds, notEmpty)
          if not sep1.isnil:
            ads.add sep1
          content.add $(await articleEntry(ar))
          content.add $ads
      if content.len == 0:
        let r = buildHtml(tdiv(class = "search-results")):
          text "No results found."
        content.add $r
  else:
    let r = buildHtml(tdiv(class = "search-results")):
      text "Search query is empty."
    content.add $r
  when defined(adsense):
    content.add ADSENSE_SEARCH
  let
    footer = await pageFooter(topic, "s", home = false)
  let fromcat = if topic != "": fmt" (from category: {topic})" else: ""
  let tree = await buildPage(title = fmt"""Search results for: "{keywords}"{fromcat}""",
                      content = verbatim(content),
                      slug = "/s/" & kws,
                      lang = lang,
                      pagefooter = footer,
                      topic = "") # NOTE: Search box is sitewide
  checkNil(tree):
    return (await processPage(lang, "", tree, relpath = capts.path)).asHtml(
        minify_css = true)

proc buildSuggestList*(topic, input: string, prefix = ""): Future[
    string] {.async.} =
  let sgs = await suggest(topic, input)
  let p = buildHtml(ul(class = "search-suggest")):
    for sug in sgs:
      li():
        a(href = ($(config.websiteUrl / (if topic != "g": topic / "s" else: "s") / encodeUrl((
                if prefix != "": prefix & " " else: "") &
                sug)))): # FIXME: should `sug` be encoded?
          text sug
  if sgs.len > 0:
    p.find(VNodeKind.li).setAttr("class", "selected")
  return $p


{.pop.}
{.pop.}

