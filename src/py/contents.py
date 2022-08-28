import warnings
from typing import List

import feedfinder2 as ff2
import feedparser as fep

import articles as art
import config as cfg
import scheduler as sched
import utils as ut
from blacklist import exclude_blacklist
from log import logger
from sites import Site

warnings.simplefilter("ignore")

FEEDS: List[str] = []
ARTICLES: List[dict] = []
LAST_SOURCE = None
FEEDFINDER_DATA = dict()

# overwrite feedfinder to accept raw data
setattr(ff2.FeedFinder, "get_feed", lambda _, url: FEEDFINDER_DATA.pop(url, ""))


def parsesource(url, topic, site: Site):
    global FEEDFINDER_DATA, LAST_SOURCE
    FEEDFINDER_DATA[url] = data = ut.fetch_data(url)
    if data:
        f = ff2.find_feeds(url)
        f = exclude_blacklist(site, f)
        if f:
            logger.info("Adding %s feeds.", len(f))
            FEEDS.extend(f)
        a = art.fillarticle(url, data, topic, site)
        if a:
            logger.info("Adding %s articles", len(a))
            ARTICLES.append(a)
        elif len(f) == 0:
            logger.info("Url is neither an article nor a feed source. (%s)", url)
        LAST_SOURCE = (f, a)
    else:
        LAST_SOURCE = (None, None)


def parsearticle(url, topic, site: Site):
    data = ut.fetch_data(url)
    if data:
        a = art.fillarticle(url, data, topic, site)
        if a:
            ARTICLES.append(a)
            return a
        else:
            logger.info("Couldn't parse an article from url %s .", url)


def parsefeed(f):
    return fep.parse(ut.fetch_data(f))


def fromsources(sources, topic, site: Site, n=cfg.POOL_SIZE):
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global FEEDS, ARTICLES
    sched.initPool()
    FEEDS = []
    ARTICLES = []
    jobs = []
    logger.info("Starting to collect articles/feeds from %d sources.", len(sources))
    for entry in sources:
        url = entry.get("url")
        if not url:
            continue
        logger.info("Fetching articles/feeds from %s", url)
        j = sched.apply(parsesource, url, topic, site)
        jobs.append(j)
    for n, j in enumerate(jobs):
        logger.info("Waiting for job: %s.", n)
        j.wait()

    logger.info("Source parsing Done")
    FEEDS = ut.dedup(FEEDS)
    logger.info(
        "Found %d feeds and %d articles in %d sources.",
        len(FEEDS),
        len(ARTICLES),
        len(sources),
    )
    return (ARTICLES, FEEDS)


def fromfeeds(sources, site: Site, n=cfg.POOL_SIZE):
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global ARTICLES
    sched.initPool()
    ARTICLES = []
    jobs = []
    for entry in sources:
        url = entry.get("url")
        topic = entry.get("topic")
        if not url:
            continue
        logger.info("Fetching articles from %s", url)
        j = sched.apply(parsearticle, url, topic, site)
        jobs.append(j)
    for n, j in enumerate(jobs):
        j.wait()
        logger.info("Waiting for job: %s.", n)

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
