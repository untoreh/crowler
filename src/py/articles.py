import config as cfg
import lassie as la
import utils as ut
from goose3 import Goose
import nltk
import spacy
import trafilatura as _tra
import warnings
# NOTE: Check scikit version from time to time
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from profanity_check import predict_prob

if not spacy.util.get_installed_models():
    cfg.setproxies("")
    spacy.cli.download(cfg.SPACY_MODEL)
    cfg.setproxies()

gs = Goose()

if not hasattr(nltk, "punkt"):
    nltk.download("punkt")


def isrelevant(title, body):
    """String BODY is relevant if it contains at least one word from TITLE."""
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


def g2n(g):
    """Normalizes goose3.Article keys to NewsArticle ones."""
    n = dict()
    n["authors"] = g["author"]
    n["date_publish"] = g["publish_date"]
    n["title"] = g["title"] or g["opengraph"].get("title")
    n["description"] = g["description"] or g["meta"]["description"]
    n["maintext"] = g["cleaned_text"]
    n["language"] = g["meta"].get("lang", "en")
    n["url"] = g["meta"].get("canonical") or g["opengraph"].get("url")
    n["image_url"] = g["opengraph"].get("image") or g["meta"].get("image")


def fillnews(a, url):
    """Ensure normalize NewsArticle keys to one."""
    data = a.get_dict()
    if not data.get("url"):
        data["url"] = url
    if not data.get("title"):
        data["title"] = data["title_rss"] or data["title_page"]
    if not data.get("maintext"):
        data["maintext"] = data.get("text")
    # data["image_url"] =


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


def fillarticle(url, data):
    """Using `trafilatura`, `goose` and `lassie` machinery to parse article data."""
    final = dict()
    tra = trafi(url, data)
    goo = goose(url, data).infos
    if tra is None:
        tra = {}
    if goo is None:
        goo = {}
    la = {}
    # first try content

    final["content"] = tra["text"] or goo["cleaned_text"]
    final["title"] = tra["title"] or goo.get("title")
    if (
        not final["content"]
        or not isrelevant(final["title"], final["content"])
        or predict_prob(final["content"]) > cfg.PROFANITY_THRESHOLD
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
    if not final["imageUrl"]:
        final["imageUrl"] = goo["image"] or goo["opengraph"].get("image")
    if not final["icon"]:
        final["icon"] = goo["meta"]["favicon"]
    final["url"] = tra["url"] or goo["meta"]["canonical"] or la["url"]
    final["lang"] = goo["meta"]["lang"]
    if not final["lang"]:
        l = la.get("locale", "")
        if l:
            assert isinstance(l, str)
            final["lang"] = l.split("_")[0]
        else:
            final["lang"] = cfg.DEFAULT_LANG
    return final
