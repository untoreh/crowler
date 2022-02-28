import warnings
from multiprocessing.pool import ThreadPool
from typing import List

import articles as art
import config as cfg
import utils as ut
from log import logger

import feedfinder2 as ff2
import feedparser as fep

warnings.simplefilter("ignore")

FEEDS: List[str] = []
ARTICLES: List[dict] = []
LAST_SOURCE = None
FEEDFINDER_DATA = dict()

# overwrite feedfinder to accept raw data
setattr(ff2.FeedFinder, "get_feed", lambda url: FEEDFINDER_DATA.pop(url, ""))


def parsesource(url):
    global FEEDFINDER_DATA, LAST_SOURCE
    FEEDFINDER_DATA[url] = data = ut.fetch_data(url)
    if data:
        f = ff2.find_feeds(url)
        if f:
            logger.info("Adding %s feeds.", len(f))
            FEEDS.extend(f)
        a = art.fillarticle(url, data)
        if a:
            logger.info("Adding %s articles", len(a))
            ARTICLES.append(a)
        elif len(f) == 0:
            logger.info("Url is neither an article nor a feed source. (%s)", url)
        LAST_SOURCE = (f, a)
    else:
        LAST_SOURCE = (None, None)


def parsearticle(url):
    data = ut.fetch_data(url)
    if data:
        a = art.fillarticle(url, data)
        if a:
            ARTICLES.append(a)
        else:
            logger.info("Couldn't parse an article from url %s .", url)


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
    logger.info("Starting to collect articles/feeds from %d sources.", len(sources))
    with ThreadPool(processes=n) as pool:
        for entry in sources:
            url = entry.get("url")
            if not url:
                continue
            logger.info("Fetching articles/feeds from %s", url)
            j = pool.apply_async(parsesource, args=(url,))
            jobs.append(j)
        for n, j in enumerate(jobs):
            j.wait()
            logger.info("Waiting for job: %s.", n)

    if use_proxies:
        cfg.setproxies()
    logger.info("Source parsing Done")
    FEEDS = ut.dedup(FEEDS)
    logger.info(
        "Found %d feeds and %d articles in %d sources.",
        len(FEEDS),
        len(ARTICLES),
        len(sources),
    )
    return (ARTICLES, FEEDS)


def fromfeeds(sources, n=cfg.POOL_SIZE, use_proxies=True):
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global ARTICLES
    ARTICLES = []
    if use_proxies:
        cfg.setproxies()
    jobs = []
    with ThreadPool(processes=n) as pool:
        for entry in sources:
            url = entry.get("url")
            if not url:
                continue
            logger.info("Fetching articles from %s", url)
            j = pool.apply_async(parsearticle, args=(url,))
            jobs.append(j)
        for n, j in enumerate(jobs):
            j.wait()
            logger.info("Waiting for job: %s.", n)

    if use_proxies:
        cfg.setproxies()
    logger.info("Articles parsing Done")
    logger.info(
        "Found %d articles in %d sources.",
        len(ARTICLES),
        len(sources),
    )
    return ARTICLES


def processfeed(f):
    try:
        pf = parsefeed(f)
        if not pf["entries"]:
            return []
    except:
        return False
