from retry import retry
import config as cfg
import lassie as la
import utils as ut
from newsplease import NewsPlease
from goose3 import Goose
from newspaper import Article as N3KArticle
import nltk
import spacy


if not spacy.util.get_installed_models():
    cfg.setproxies("")
    spacy.cli.download(cfg.SPACY_MODEL)
    cfg.setproxies()

gs = Goose()

if not hasattr(nltk, "punkt"):
    nltk.download("punkt")


@retry(ValueError, tries=3)
def goose(l, data=None):
    if data is None: data = ut.fetch_data(l)
    return gs.extract(raw_html=data)


@retry(ValueError, tries=3)
def n3k(l, data=None, nlp=False):
    a = N3KArticle(l)
    if data is None: data = ut.fetch_data(l)
    a.download(input_html=data)
    a.parse()
    nlp and a.nlp()
    return a


@retry(ValueError, tries=3)
def news(l, data=None):
    if data is None: data = ut.fetch_data(l)
    return NewsPlease.from_html(data)

LASSIE_DATA = dict()
setattr(la.Lassie, "_retrieve_content", lambda _, url: (LASSIE_DATA.pop(url, ""), 200))

def lassie(l, data=None):
    LASSIE_DATA[l] = ut.fetch_data(l) if data is None else data
    return la.fetch(l)
