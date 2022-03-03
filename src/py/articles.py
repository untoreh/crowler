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

# NOTE: Check scikit version from time to time
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from profanity_check import predict_prob

if not spacy.util.get_installed_models():
    cfg.setproxies(None)
    spacy.cli.download(cfg.SPACY_MODEL)
    cfg.setproxies()

gs = Goose()

if not hasattr(nltk, "punkt"):
    nltk.download("punkt")


def isrelevant(title, body):
    """String BODY is relevant if it contains at least one word from TITLE."""
    if not title or not body:
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


def trafi(url, data=None):
    if data is None:
        data = ut.fetch_data(url)
    return _tra.bare_extraction(
        data,
        url,
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
    final["content"] = tra["text"] or goo["cleaned_text"]
    final["content"] = replace_profanity(final["content"])
    final["title"] = tra["title"] or goo.get("title")
    if (
        not final["content"]
        or not isrelevant(final["title"], final["content"])
    ):
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
    la = lassie_img(url, data, final)
    if not final["icon"]:
        final["icon"] = goo["meta"]["favicon"]
    if not final["imageUrl"] or final["imageUrl"] == final["icon"]:
        final["imageUrl"] = goo["image"] or goo["opengraph"].get("image")
        if final["imageUrl"] == final["icon"]:
            final["imageUrl"] = ""
    final["url"] = tra["url"] or goo["meta"]["canonical"] or la["url"]
    final["lang"] = goo["meta"]["lang"]
    if not final["lang"]:
        l = la.get("locale", "")
        if l:
            assert isinstance(l, str)
            final["lang"] = l.split("_")[0]
        else:
            final["lang"] = cfg.DEFAULT_LANG
    final["topic"] = topic
    final["tags"] = rake(final["content"])
    return final
