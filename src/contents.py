import warnings
from multiprocessing.pool import ThreadPool
from typing import List

import feedfinder2 as ff2
import feedparser as fep
from retry import retry

import articles as art
import config as cfg
import utils as ut
from utils import logger

# import textop as to

warnings.simplefilter("ignore")

FEEDS: List[str] = []
ARTICLES: List[dict] = []
LAST_SOURCE = None
FEEDFINDER_DATA = dict()

# overwrite feedfinder to accept raw data
setattr(ff2.FeedFinder, "get_feed", lambda _, url: FEEDFINDER_DATA.pop(url, ""))


def isrelevant(title, body):
    t_words = set(title.split())
    for w in ut.splitStr(body):
        if w in t_words:
            return True
    return False


@retry(ValueError, tries=3)
def parsesource(url):
    global FEEDFINDER_DATA, LAST_SOURCE
    FEEDFINDER_DATA[url] = data = ut.fetch_data(url)
    if data:
        f = ff2.find_feeds(url)
        if f:
            logger.info("Adding %s feeds.", len(f))
            FEEDS.extend(f)
        content = art.news(url, data)
        if isrelevant(content.title, content.maintext):
            ARTICLES.append(content.get_dict())
        else:
            content = art.goose(url, data)
            if isrelevant(content.title, content.cleaned_text):
                ARTICLES.append(content.infos)
            elif len(f) == 0:
                logger.warning("Url is neither an article nor a feed source. (%s)", url)
        LAST_SOURCE = (f, content)
    else:
        LAST_SOURCE = (None, None)


@retry(ValueError, tries=3)
def parsefeed(f):
    return fep.parse(ut.fetch_data(f))


def fromsources(sources, n=cfg.POOL_SIZE, use_proxies=True):
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global FEEDS, ARTICLES
    FEEDS = []
    ARTICLES = []
    if use_proxies:
        cfg.setproxies()
    jobs = []
    with ThreadPool(processes=n) as pool:
        for entry in sources:
            url = entry["url"]
            logger.info("Fetching feeds from %s", url)
            j = pool.apply_async(parsesource, args=(url,))
            jobs.append(j)
        for n, j in enumerate(jobs):
            j.wait()
            logger.info("Waiting for job: %s.", n)

    if use_proxies:
        cfg.setproxies("")
    logger.info("Source parsing Done")
    FEEDS = ut.dedup(FEEDS)
    logger.info(
        "Found %d feeds and %d articles in %d sources.",
        len(FEEDS),
        len(ARTICLES),
        len(sources),
    )
    return (ARTICLES, FEEDS)


def processfeed(f):
    try:
        pf = parsefeed(f)
        if not pf["entries"]:
            return []
    except:
        return False
