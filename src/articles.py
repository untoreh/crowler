from retry import retry
import config as cfg
import json
import feedparser as fep
import lassie as la
from newsplease import NewsPlease, SimpleCrawler
from goose3 import Goose
from newspaper import Article as N3KArticle
import nltk
import spacy


def __init__():
    global sources, feeds, gs, sc

    if not spacy.util.get_installed_models():
        cfg.setproxies("")
        spacy.cli.download(cfg.SPACY_MODEL)
        cfg.setproxies()

    gs = Goose()
    sc = SimpleCrawler()

    if not hasattr(nltk, "punkt"):
        nltk.download("punkt")

    with open(cfg.SRC_FILE, "r") as f:
        sources = json.load(f)
    with open(cfg.FEEDS_FILE, "r") as f:
        feeds = json.load(f)

__init__()


def fetch_data(url):
    data = sc.fetch_url(url)
    if data is None:
        raise ValueError(f"Failed crawling feed url: {url}.")
    return data


@retry(ValueError, tries=3)
def parsefeed(f=feeds[0]):
    return fep.parse(fetch_data(f))


@retry(ValueError, tries=3)
def goose(l):
    data = fetch_data(l)
    return gs.extract(raw_html=data)


@retry(ValueError, tries=3)
def n3k(l, nlp=False):
    a = N3KArticle(l)
    data = fetch_data(l)
    a.download(input_html=data)
    a.parse()
    nlp and a.nlp()
    return a

@retry(ValueError, tries=3)
def news(l):
    data = fetch_data(l)
    return NewsPlease.from_html(data)

def lassie(l):
    return la.fetch(l)

feed = parsefeed(feeds[0])
links = [et.link for et in feed.entries]
