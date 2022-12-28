import re
import warnings
from typing import Callable, List, NamedTuple

import lassie as la
import nltk
import numpy as np
import spacy
import trafilatura as _tra
from goose3 import Goose
from urllib3.util.url import Url, parse_url

import config as cfg
import log
import proxies_pb as pb
import translator as tr
import utils as ut
from sites import Site
from sources import get_images
from tagging import rake
from praw.reddit import Submission
from praw import Reddit
from embeddify import Embedder
from datetime import datetime

reddit: Reddit = None
emb: Embedder = None

# NOTE: Check scikit version from time to time
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from profanity_check import predict_prob


def check_spacy_model():
    info: dict = spacy.info()
    pp = info.get("pipelines", dict())
    model_version = pp.get(cfg.SPACY_MODEL, "")
    spacy_version = info.get("spacy_version", "")
    lsv_path = cfg.CACHE_DIR / "last_spacy_version.txt"
    if not cfg.CACHE_DIR.exists():
        import os

        os.makedirs(cfg.CACHE_DIR)
    lsv_path.touch()
    with open(lsv_path, "r") as f:
        last_spacy_version = f.read()
        if last_spacy_version == spacy_version:
            return
    assert spacy_version != ""
    if model_version != spacy_version:
        with pb.http_opts():
            spacy.cli.download(cfg.SPACY_MODEL)
        with open(cfg.CACHE_DIR / "last_spacy_version.txt", "w") as f:
            f.write(spacy_version)


check_spacy_model()

gs = Goose()

if not hasattr(nltk, "punkt"):
    nltk.download("punkt")

char_start_rgx = re.compile(r"^[^a-zA-Z\-\*\=]")
noise_rgx = re.compile(
    r"(cookies?)|(policy)|(privacy)|(browser)|(firefox)|(chrome)|(mozilla)|(\sads?\s)|(copyright)|(\slogo\s)|(trademark)|(advertisements?)|(javascript)|(supported)|(block)|(available)|(country?i?e?s?)|(slow)|(loading)|(allowe?d?)|(sign\sin)|(sign\s?up)|(sign\s?on)|(log\s?in)|(user menu)|(can\'t be reached)|(create)|(follow)|(home)|(popular)|(feeds?)|(denied)|(access denied)|(r\/)",
    re.IGNORECASE,
)


def isnoise(content, thresh=0.005) -> bool:
    m = re.findall(noise_rgx, content)
    if len(m) / len(content) > thresh:
        return True
    return False


def purge_bad_articles(s: Site):
    def clear_topic(topic):
        done = s.load_done(topic)
        for n in range(len(done)):
            page_arts = done[n]
            for i, a in enumerate(page_arts):
                if a and len(a.get("content", "")) > 0:
                    if isnoise(a["content"]):
                        page_arts[i] = None

    for topic in s.load_topics()[1].keys():
        clear_topic(topic)


class Relevance:
    content = chars = noise = body = True

    def __str__(self):
        return f"cnt: {self.content}, chr: {self.chars}, nse: {self.noise}, bod: {self.body}"


"""Last relevance score (debug)."""
LRS = Relevance()


def reset_rev():
    LRS.body = True
    LRS.content = True
    LRS.chars = True
    LRS.noise = True


def isrelevant(title, body):
    """String BODY is relevant if it contains at least one word from TITLE."""
    reset_rev()
    if not title or not body:
        LRS.content = False
        return False
    # only allow contents that don't start with special chars to avoid spam/code blocks
    if re.match(char_start_rgx, body):
        LRS.chars = False
        return False
    # skip error/messages/warnings pages
    if isnoise(title) or isnoise(body):
        LRS.noise = False
        return False
    t_words = set(title.split())
    for w in ut.splitStr(body):
        if w in t_words:
            return True
    LRS.body = False
    return False


def goose(l, data=None):
    if data is None:
        data = ut.fetch_data(l)
    return gs.extract(raw_html=data)


LASSIE_DATA = dict()
setattr(la.Lassie, "_retrieve_content", lambda _, url: (LASSIE_DATA.pop(url, ""), 200))


def lassie(l, data=None):
    LASSIE_DATA[l] = ut.fetch_data(l) if data is None else data
    return la.fetch(l)


def lassie_img(url, data, final):
    la = lassie(url, data)
    img = icon = ""
    for im in la["images"]:
        if im.get("type") == "icon":
            if not icon:
                icon = im["src"]
        elif not img:
            img = im["src"]
        if img and icon:
            break
    final["imageUrl"] = img
    if "icon" not in final:
        final["icon"] = icon
    return la


def trafi(url, data=None, precise=False):
    if data is None:
        data = ut.fetch_data(url)
    return _tra.bare_extraction(
        data,
        url,
        favor_precision=precise,
        include_comments=False,
        include_images=True,
        include_formatting=True,
        include_links=False,
    )


url_rgx = re.compile(
    r"https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()!@:%_\+.~#?&\/\/=]*)"
)
profanity_rgx = re.compile(r"(\n|\s|\.|\?|\!)")


def replace_profanity(data):
    sents = np.asarray(re.split(profanity_rgx, data))
    probs = predict_prob(sents)
    match = probs > cfg.PROFANITY_THRESHOLD
    if len(np.where(match)) / len(sents) > 0.8:
        return None
    sents[match] = " [...] "
    return "".join(sents)


def test_profanity(content):
    """Test which non token based splitting method is better for profanity checking.
    RESULT: Splitting by new line seems the most balanced.
    """
    print("Testing profanity...")
    if "np" not in globals():
        import numpy as np

    ff = np.asarray(content.split("."))
    pp = predict_prob(ff)
    ff2 = np.asarray(content.split())
    pp2 = predict_prob(ff2)
    ff3 = np.asarray(content.split("\n"))
    pp3 = predict_prob(ff3)
    ff4 = np.asarray([content])
    pp4 = predict_prob(ff4)
    print(
        "dot:",
        ff[pp > 0.5],
        np.max(pp),
        "def:",
        ff2[pp2 > 0.5],
        np.max(pp2),
        "newline:",
        ff3[pp3 > 0.5],
        np.max(pp3),
        "none:",
        ff4[pp4 > 0.5],
        pp4,
    )


def abs_url(url: str, baseurl) -> str:
    if url and baseurl:
        u = parse_url(url)._asdict()
        if not u["host"]:
            b = parse_url(baseurl)
            u["scheme"] = b.scheme
            u["host"] = b.host
            u["auth"] = b.auth
            u["port"] = b.port
            return str(Url(**u))
    return url


def remove_urls(title: str | None) -> str | None:
    if title is None:
        return
    clean_title = re.sub(url_rgx, "", title)
    if re.match(r"^\s*$", clean_title):
        nows = re.sub(r"\s", "", title)
        try:
            url = parse_url(nows)
            return url.path.replace("/", " ").title()
        except:
            return
    else:
        return clean_title.strip()


def add_img(final, urls: List[str], site: Site) -> bool:
    try:
        for url in urls:
            if (
                url
                and (url != final["icon"])
                and (url not in site.img_bloom)
                and ut.is_img_url(url)
            ):
                final["imageUrl"] = url
                return True
        return False
    except:
        return False


def search_img(final: dict, site: Site):
    """Attempt to search for an image for the article with search engines."""
    imgs = get_images(final["title"])
    for img in imgs:
        if img.url not in site.img_bloom and ut.is_img_url(img.url):
            final["imageUrl"] = img.url
            final["imageTitle"] = img.title
            final["imageOrigin"] = img.origin
            site.img_bloom.add(img.url)
            break


rgx_1 = re.compile(r"\.\s*\n")
rgx_2 = re.compile(r"[^a-zA-Z0-9\n\s]{3,}|(.\s+)\1{2,}")
rgx_3 = re.compile(r" {2,}")
rgx_4 = re.compile(r"(?:\!\[.*?\].*?\(.*?\))|(?:\!\[.*?\).*?\n?)")


def clean_content(content: str):
    """"""
    try:
        # some weird broken md links
        content = re.sub(rgx_4, "", content)
        # double new lines for better formatting
        content = re.sub(rgx_1, "\n\n", content)
        # clean repeated charaters
        content = re.sub(rgx_2, "", content)
        # compact whitespace
        content = re.sub(rgx_3, "", content)
        return content
    except:
        return content


def maybe_translate(title, content, lang, logf):
    # Ensure articles are always in the chosen source language
    if lang != tr.SLang.code:
        logf("pyart: different lang? %s", lang)
        content = tr.translate(content, to_lang=tr.SLang.code, from_lang=lang)
        title = tr.translate(title, to_lang=tr.SLang.code, from_lang=lang)
    return (title, content)


def process_content(final, logf):

    final["title"], final["content"] = maybe_translate(
        final["title"], final["content"], final["lang"], logf
    )

    final["content"] = replace_profanity(final["content"])

    if not final["content"] or not isrelevant(final["title"], final["content"]):
        logf("content not relevant (%d)", len(final["content"] or ""))
        return {}

    final["content"] = clean_content(final["content"])
    if not final["content"]:
        logf("cleaned content is empty.")
        return {}

    return final


def ensure_reddit():
    global reddit, emb
    if reddit is None:
        reddit = Reddit(
            client_id="I0vScOPlsiZ47b6dm9WWoQ",
            client_secret="1Uq8QtEkVeRKKy4ryjpRsqsaXgWHsw",
            user_agent="wslBot",
        )
    if emb is None:
        emb = Embedder()


def embed(s: Submission, final):
    try:
        if "oembed" in s.media:
            o = s.media["oembed"]
            if "thumbnail_url" in o:
                final["imageUrl"] = o["thumbnail_url"]
                final["imageTitle"] = o.get("title", s.title)
                final["imageOrigin"] = s.url
            if "html" in o:
                final["content"] = o["html"]
        else:
            vid = s.media["reddit_video"]
            url = vid["fallback_url"]
            ext = parse_url(url).path.split(".")[-1]
            width = vid["width"]
            height = vid["height"]
            final["content"] = f"""\
<video width="{width}" height="{height}" controls>
<source src="{url}" type="video/{ext}">
Your browser does not support the video tag.
</video>
"""
    except:
        embed_code = emb(s.url)
        if embed_code == s.url:
            return None


def process_reddit(url, topic, site, logf):
    ensure_reddit()
    final = {}
    try:
        s = reddit.submission(url=url)
        final["title"] = s.title
        if not final["title"]:
            return {}
        if s.media:
            embed(s, final)
            if not final["content"]:
                logf("reddit failed to process media")
                return {}
            final["tags"] = rake(final["content"])
        else:
            content = s.selftext
            if len(content) < cfg.ART_MIN_LEN:
                logf("reddit content too short, appending comments")
            comms = []
            maxComms = 20  # NOTE: don't process more than 20 comments
            target_len = len(content)
            final["lang"] = tr.detect(content) if content else tr.detect(final["title"])
            title = final["title"]
            c = 0
            for com in s.comments:
                if com.body:
                    com_final = {
                        "lang": final["lang"],
                        "title": title,
                        "content": com.body,
                    }
                    if process_content(com_final, logf):
                        comms.append(com_final["content"])
                        target_len += len(comms[-1])
                        if target_len >= cfg.ART_MIN_LEN:
                            break
                c += 1
                if c >= maxComms:
                    break
            if target_len < cfg.ART_MIN_LEN:
                logf("target len not men %s", target_len)
                return {}
            commStr = "\n".join(comms)
            final["content"] = f"{content}\n{commStr}" if content else commStr
            final["tags"] = rake(final["content"])

        final["slug"] = ut.slugify(final["title"])
        final["desc"] = s.subreddit.title
        final["author"] = s.author.name if s.author else s.title
        final["pubDate"] = str(datetime.fromtimestamp(s.created_utc))
        final["url"] = s.shortlink
        final["topic"] = topic
        # Image
        if ut.is_img_url(s.url):
            final["imageUrl"] = s.url
            final["imageTitle"] = s.title
            final["imageOrigin"] = url
        else:
            search_img(final, site)
        if "imageUrl" in final:
            site.img_bloom.add(final["imageUrl"])
        final["source"] = "reddit"
        return final
    except:
        import traceback

        traceback.print_exc()
        log.warn("failed to process reddit %s", url)


"""Last Parsed Article (debugging)"""
LPA = {}


def fillarticle(url, data, topic, site: Site):
    """Using `trafilatura`, `goose` and `lassie` machinery to parse article data."""
    idf = hash(url)

    def logit(s, *args):
        log.info(f"pyart(%d): {s}", idf, *args)

    if "reddit." in url:
        final = process_reddit(url, topic, site, logit)
        if not final:
            return {}
        else:
            logit("parse successfull")
            return final

    logit("parsing url: %s", url)
    final, tra, goo, la = {}, {}, {}, {}

    def save_lpa():
        LPA["final"] = final
        LPA["tra"] = tra
        LPA["goo"] = goo

    try:
        try:
            tra = trafi(url, data) or {}
        except:
            tra = {}
        try:
            goo = goose(url, data).infos or {}
        except:
            goo = {}
        assert isinstance(tra, dict)
        assert isinstance(goo, dict)

        # first try content
        tra_len = len(tra.get("text", ""))
        if tra_len and tra_len >= len(goo.get("cleaned_text", "")):
            src = "traf"
            final["content"] = tra["text"]
            final["source"] = "tra"
        else:
            src = "goose"
            final["content"] = goo["cleaned_text"]
            final["source"] = "goo"
        logit("using content from %s (%d)", src, len(final["content"]))
        if len(final["content"]) < cfg.ART_MIN_LEN:
            logit("too short! %d", len(final["content"]))

        final["lang"] = tr.detect(final["content"])
        final["title"] = remove_urls(tra.get("title", "") or goo.get("title", ""))
        if not final["title"]:
            logit("no title found!")
            save_lpa()
            return {}

        final = process_content(final, logit)
        if not final:
            save_lpa()
            return {}

        final["slug"] = ut.slugify(final["title"])
        final["desc"] = tra["description"] or goo.get("meta", {}).get("description")
        final["author"] = (
            tra["author"]
            or "".join(goo.get("authors", ""))
            or tra.get("sitename")
            or goo.get("opengraph", {}).get("site_name")
        )
        final["pubDate"] = tra["date"] or goo.get("publish_date")
        url = final["url"] = tra["url"] or goo["meta"]["canonical"]

        final["topic"] = topic
        final["tags"] = rake(final["content"])

        ## Icon/Image
        try:
            la = lassie_img(url, data, final)
        except:
            pass
        if not final.get("icon", "") and goo.get("meta", ""):
            final["icon"] = abs_url(goo["meta"]["favicon"], url)
        imgUrl = final.get("imageUrl", "")
        img_dup = imgUrl in site.img_bloom
        if (not imgUrl) or img_dup or (not ut.is_img_url(imgUrl)):
            img_urls = [abs_url(goo["image"], url), goo["opengraph"].get("image", "")]
            if not add_img(final, img_urls, site):
                search_img(final, site)
        site.img_bloom.add(final["imageUrl"])
        if not final.get("imageTitle", ""):
            final["imageTitle"] = la.get("description", "") or final["desc"]
        if not final.get("imageOrigin", ""):
            final["imageOrigin"] = final.get("imageUrl", "")
    except Exception as e:
        import traceback

        traceback.print_exc()
        logit("exception %s", e)
        save_lpa()
        return {}
    logit("parse successfull")
    return final
