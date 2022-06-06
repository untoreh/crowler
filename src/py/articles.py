import config as cfg
import lassie as la
import utils as ut
from goose3 import Goose
import nltk
import spacy
import trafilatura as _tra
import warnings
import re
import numpy as np
from tagging import rake
from urllib3.util.url import Url, parse_url
import translator as tr

# NOTE: Check scikit version from time to time
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from profanity_check import predict_prob


def check_spacy_model():
    info: dict = spacy.info()
    pp = info.get("pipelines", dict())
    model_version = pp.get(cfg.SPACY_MODEL, "")
    spacy_version = info.get("spacy_version", "")
    assert spacy_version != ""
    if model_version != spacy_version:
        cfg.setproxies(None)
        spacy.cli.download(cfg.SPACY_MODEL)
        cfg.setproxies()


check_spacy_model()

gs = Goose()

if not hasattr(nltk, "punkt"):
    nltk.download("punkt")

rx_nojs = r"(Your page may be loading slowly)|(block on your account)|((avail|enable)?(?i)(javascript|js)\s*(?i)(avail|enable)?)"


def isrelevant(title, body):
    """String BODY is relevant if it contains at least one word from TITLE."""
    if not title or not body:
        return False
    # only allow contents that don't start with special chars to avoid spam/code blocks
    if re.match(r"^[^a-zA-Z]", body):
        return False
    # skip error pages
    if re.match(rx_nojs, title) or re.match(rx_nojs, body):
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
        if im["type"] == "icon":
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


profanity_rgx = re.compile("(\n|\s|\.|\?|\!)")


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

    ff = np.asarray(content.split("\\."))
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

def fillarticle(url, data, topic):
    """Using `trafilatura`, `goose` and `lassie` machinery to parse article data."""
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
    if tra["text"]:
        final["content"] = tra["text"]
        final["source"] = "tra"
    else:
        final["content"] = goo["cleaned_text"]
        final["source"] = "goo"
    if len(final["content"]) < cfg.ART_MIN_LEN:
        return {}
    final["lang"] = tr.detect(final["content"])
    final["title"] = tra["title"] or goo.get("title")
    # Ensure articles are always in the chosen source language
    if final["lang"] != tr.SLang.code:
        final["content"] = tr.translate(final["content"], target=tr.SLang.code, source=final["lang"])
        final["title"] = tr.translate(final["title"], target=tr.SLang.code, source=final["lang"])
    final["content"] = replace_profanity(final["content"])
    if (
        not final["content"]
        or not isrelevant(final["title"], final["content"])
    ):
        return {}
    # double new lines for better formatting
    final["content"] = final["content"].replace("\n", "\n\n")
    # clean repeated charaters
    final["content"] = re.sub(r"[^a-zA-Z0-9\n\s]{3,}|(.\s+)\1{2,}", "", final["content"])
    # compact whitespace
    final["content"] = re.sub(r" {2,}", "", final["content"])

    final["slug"] = ut.slugify(final["title"])
    final["desc"] = tra["description"] or goo.get("meta", {}).get("description")
    final["author"] = (
        tra["author"]
        or "".join(goo.get("authors", ""))
        or tra.get("sitename")
        or goo.get("opengraph", {}).get("site_name")
    )
    final["pubDate"] = tra["date"] or goo.get("publish_date")
    la = lassie_img(url, data, final)

    url = final["url"] = tra["url"] or goo["meta"]["canonical"] or la["url"]
    if not final["icon"]:
        final["icon"] = abs_url(goo["meta"]["favicon"], url)
    if not final["imageUrl"] or final["imageUrl"] == final["icon"]:
        final["imageUrl"] = abs_url(goo["image"] or goo["opengraph"].get("image"), url)
        if final["imageUrl"] == final["icon"]:
            final["imageUrl"] = ""
    final["topic"] = topic
    final["tags"] = rake(final["content"])
    return final
