{.push hint[DuplicateModuleImport]: off.}
import
  karax / [karaxdsl, vstyles],
  uri,
  sequtils,
  unicode,
  xmltree,
  algorithm,
  chronos,
  htmlparser

import html_misc,
       translate,
       translate_lang,
       amp,
       search,
       ads

const tplRep = @{"WEBSITE_DOMAIN": WEBSITE_DOMAIN}
const ppRep = @{"WEBSITE_URL": $WEBSITE_URL.combine(),
                 "WEBSITE_DOMAIN": WEBSITE_DOMAIN}

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
  let maxlen = min(alen, ARTICLE_EXCERPT_SIZE)
  if maxlen == alen:
    return a.content
  else:
    let runesize = runeLenAt(a.content, maxlen)
    # If article contains html tags, the excerpt might have broken html
    return parseHtml(a.content[0..maxlen+runesize]).innerText & "..."

import htmlparser
proc articleEntry(ar: Article): Future[VNode] {.async.} =
  let relpath = getArticlePath(ar)
  try:
    return buildHtml(article(class = "entry")):
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
      buildImgUrl(ar)
      tdiv(class = "entry-content"):
        verbatim(articleExcerpt(ar))
        a(class = "entry-more", href = relpath):
          text "[continue]"
      hr()
  except:
    let e = getCurrentException()[]
    warn "articles: entry creation failed {e}"
    raise getCurrentException()

proc buildShortPosts*(arts: seq[Article], homepage = false): Future[
    string] {.async.} =
  for a in arts:
    result.add $(await articleEntry(a))

template topicPage*(topic: string, pagenum: string, istop = false) {.dirty.} =
  ## Writes a single page (fetching its related articles, if its not a template) to storage
  let arts = await getDoneArticles(topic, pagenum = pagenum.parseInt)
  debug "topics: topic page for page {pagenum} ({len(arts)})"
  let content = await buildShortPosts(arts)
  # if the page is not finalized, it is the homepage
  let footer = await pageFooter(topic, pagenum, home = istop)
  let pagetree = await buildPage(title = "",       # this is NOT a `title` tag
    content = verbatim(content),
    slug = pagenum,
    pagefooter = footer,
    topic = topic)

{.experimental: "strictnotnil".}
{.push gcsafe.}
proc processPage*(lang, amp: string, tree: VNode not nil, relpath = "index"): Future[
    VNode] {.async.} =
  if lang in TLangsCodes:
    let
      filedir = SITE_PATH
      tpath = filedir / lang / relpath
    var fc = initFileContext(tree, filedir, relpath,
          (src: SLang.code, trg: lang), tpath)
    debug "page: translating page to {lang}"
    try:
      result = await translateLang(fc)
    except:
      let e = getCurrentException()[]
      debug "page: {e} \n Translation failed."
  else:
    result = tree
  if result.isnil:
    error("page: tree cannot be nil")
  if amp != "":
    debug "page: amping"
    result = await result.ampPage

proc pageFromTemplate*(tpl, lang, amp: string): Future[string] {.async.} =
  var txt = await readfileAsync(ASSETS_PATH / "templates" / tpl & ".html")
  let (vars, title, desc) = case tpl:
    of "dmca": (tplRep, "DMCA", fmt"dmca compliance for {WEBSITE_DOMAIN}")
    of "tos": (ppRep, "Terms of Service",
        fmt"Terms of Service for {WEBSITE_DOMAIN}")
    of "privacy-policy": (ppRep, "Privacy Policy",
        fmt"Privacy Policy for {WEBSITE_DOMAIN}")
    else: (tplRep, tpl, "")
  txt = multiReplace(txt, vars)
  let
    slug = slugify(title)
    page = await buildPage(title = title, content = txt, wrap=true)
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
    let post = await buildPost(a)
    if not post.isnil:
      debug "article: processing"
      return await processPage(capts.lang, capts.amp, post, relpath = capts.art)
  debug "article: could not fetch python article."

proc articleHtml*(capts: auto): Future[string] {.gcsafe, async.} =
  let t = await articleTree(capts)
  return if not t.isnil:
               t.asHtml(minify_css = (capts.amp == ""))
           else: ""

proc buildHomePage*(lang, amp: string): Future[(VNode, VNode)] {.async.} =
  await syncTopics()
  var a: Article
  withPyLock:
    a = default(Article)
  var
    nTopics = len(topicsCache)
    narts = 0
    content: string
    processed: HashSet[string]
    trial = 0
    maxTries = cfg.HOME_ARTS * 3

  while nArts < cfg.HOME_ARTS and trial < maxTries:
    trial.inc
    var topic: string
    withPyLock:
      topic = site[].get_random_topic().to(string)
      if topic == "": # this can happen if we ran out of topics
        continue
    let arts = await getLastArticles(topic, 1)
    if len(arts) > 0:
      let ar = arts[0]
      if not (ar.slug in processed):
        content.add $(await articleEntry(ar))
        processed.incl ar.slug
        nArts.inc
  let pagetree = await buildPage(title = "",
                       content = verbatim(content),
                       slug = "",
                       desc = WEBSITE_DESCRIPTION)
  checkNil(pagetree):
    return (pagetree, await processPage(lang, amp, pagetree))

proc buildSearchPage*(topic: string, kws: string, lang: string): Future[
    string] {.async.} =
  ## Builds a search page with 10 entries
  debug "search: lang:{lang}, topic:{topic}, kws:{kws}"
  var content, keywords: string
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
          content.add $(await articleEntry(ar))
      if content.len == 0:
        let r = buildHtml(tdiv(class = "search-results")):
          text "No results found."
        content.add $r
  else:
    let r = buildHtml(tdiv(class = "search-results")):
      text "Search query is empty."
    content.add $r
  let
    footer = await pageFooter(topic, "s", home = false)
  let fromcat = if topic != "": fmt" (from category: {topic})" else: ""
  let tree = await buildPage(title = fmt"""Search results for: "{keywords}"{fromcat}""",
                      content = verbatim(content),
                      slug = "/s/" & kws,
                      pagefooter = footer,
                      topic = topic)
  if not tree.isnil:
    return (await processPage(lang, "", tree)).asHtml(minify_css = true)

proc buildSuggestList*(topic, input: string, prefix = ""): Future[
    string] {.async.} =
  let sgs = await suggest(topic, input)
  let p = buildHtml(ul(class = "search-suggest")):
    for sug in sgs:
      li():
        a(href = ($(WEBSITE_URL / (if topic != "g": topic / "s" else: "s") / encodeUrl((
                if prefix != "": prefix & " " else: "") &
                sug)))): # FIXME: should `sug` be encoded?
          text sug
  if sgs.len > 0:
    p.find(VNodeKind.li).setAttr("class", "selected")
  return $p


{.pop.}
{.pop.}

when isMainModule:
  import cfg
  echo buildHomePage("en", "")
