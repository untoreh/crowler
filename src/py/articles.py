import re
import warnings
from typing import Callable, List

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
noise_rgx = re.compile(r"(cookies?)|(policy)|(privacy)|(browser)|(firefox)|(chrome)|(mozilla)|(\sads?\s)|(copyright)|(\slogo\s)|(trademark)|(javascript)|(supported)|(block)|(available)|(country?i?e?s?)|(slow)|(loading)(allowe?d?)", re.IGNORECASE)

def isnoise(content, thresh=0.005) -> bool:
    m = re.findall(noise_rgx, content)
    if len(m) / len(content) > thresh:
        return True

def isrelevant(title, body):
    """String BODY is relevant if it contains at least one word from TITLE."""
    if not title or not body:
        return False
    # only allow contents that don't start with special chars to avoid spam/code blocks
    if re.match(char_start_rgx, body):
        return False
    # skip error/messages/warnings pages
    if isnoise(title) or isnoise(body):
        return False
    t_words = set(title.split())
    for w in ut.splitStr(body):
        if w in t_words:
            return True
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


def add_img(final, urls: List[Callable], site: Site) -> bool:
    for f in urls:
        url = f()
        if (
            url
            and (url != final["icon"])
            and (url not in site.img_bloom)
            and ut.is_img_url(url)
        ):
            final["imageUrl"] = url
            return True
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


def fillarticle(url, data, topic, site: Site):
    """Using `trafilatura`, `goose` and `lassie` machinery to parse article data."""
    log.debug("pyarticle: parsing %s", url)
    try:
        final = dict()
        tra = trafi(url, data)
        assert isinstance(tra, dict)
        goo = goose(url, data).infos
        if tra is None:
            tra = {}
        if goo is None:
            goo = {}
        la = {}
        # first try content
        if len(tra["text"]) >= len(goo["cleaned_text"]):
            final["content"] = tra["text"]
            final["source"] = "tra"
        else:
            final["content"] = goo["cleaned_text"]
            final["source"] = "goo"
        if len(final["content"]) < cfg.ART_MIN_LEN:
            log.debug("too short!: %d, %s", len(final["content"]), url)

        final["lang"] = tr.detect(final["content"])
        final["title"] = remove_urls(tra["title"] or goo.get("title"))
        if final["title"] is None:
            return {}
        # Ensure articles are always in the chosen source language
        if final["lang"] != tr.SLang.code:
            log.debug("articles: different lang? %s", final["lang"])
            final["content"] = tr.translate(
                final["content"], to_lang=tr.SLang.code, from_lang=final["lang"]
            )
            final["title"] = tr.translate(
                final["title"], to_lang=tr.SLang.code, from_lang=final["lang"]
            )
        final["content"] = replace_profanity(final["content"])
        if not final["content"] or not isrelevant(final["title"], final["content"]):
            return {}

        final["content"] = clean_content(final["content"])
        if not final["content"]:
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
        la = lassie_img(url, data, final)
        if not final["icon"]:
            final["icon"] = abs_url(goo["meta"]["favicon"], url)
        if final["imageUrl"] in site.img_bloom or not ut.is_img_url(final["imageUrl"]):
            img_f = [
                lambda: abs_url(goo["image"], url),
                lambda: goo["opengraph"].get("image", ""),
            ]
            if not add_img(final, img_f, site):
                search_img(final, site)
        else:
            site.img_bloom.add(final["imageUrl"])
        if not final.get("imageTitle", ""):
            final["imageTitle"] = (
                la["description"] if la["description"] != final["desc"] else ""
            )
        if not final.get("imageOrigin", ""):
            final["imageOrigin"] = final["imageUrl"]
    except Exception as e:
        import traceback
        traceback.print_exc()
        log.info("articles: Exception %s", e)
        return {}
    return final
