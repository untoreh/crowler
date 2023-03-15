import warnings
from typing import Dict, List, Any
import traceback

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

FEEDS: Dict[str, Dict[str, list]] = {}
ARTICLES: Dict[str, Dict[str, list]] = {}
LAST_SOURCE: Dict[str, Any] = {}
FEEDFINDER_DATA = {}

# overwrite feedfinder to accept raw data
setattr(ff2.FeedFinder, "get_feed", lambda _, url: FEEDFINDER_DATA.pop(url, ""))


def parsesource(url, topic, site: Site):
    global FEEDFINDER_DATA, LAST_SOURCE
    FEEDFINDER_DATA[url] = data = ut.fetch_data(url)
    f = a = None
    if data:
        try:
            f = ff2.find_feeds(url)
            f = exclude_blacklist(site, f)
            if f:
                logger.info("Adding %s feeds.", len(f))
                assert isinstance(f, list)
                FEEDS[site.name][topic].extend(f)
        except:
            traceback.print_exc()
        try:
            a = art.fillarticle(url, data, topic, site)
            if a:
                logger.info("Adding article (%s)", topic)
                ARTICLES[site.name][topic].append(a)
        except:
            traceback.print_exc()
        if not f and not a:
            logger.debug("Url is neither an article nor a feed source. (%s)", url)

    LAST_SOURCE[site.name][topic] = (None, None)


def parsearticle(url, topic, site: Site):
    data = ut.fetch_data(url)
    verb = "fetch"
    if data:
        a = art.fillarticle(url, data, topic, site)
        if a:
            ARTICLES[site.name][topic].append(a)
            return a
        verb = "parse"
    logger.info("Couldn't %s an article from url %s .", verb, url)


def parsefeed(f):
    return fep.parse(ut.fetch_data(f))

def ensure_globals(site, topic):
    if site.name not in FEEDS:
        FEEDS[site.name] = {}
    if topic not in FEEDS[site.name]:
        FEEDS[site.name][topic] = []
    if site.name not in ARTICLES:
        ARTICLES[site.name] = {}
    if topic not in ARTICLES[site.name]:
        ARTICLES[site.name][topic] = []
    if site.name not in LAST_SOURCE:
        LAST_SOURCE[site.name] = {}

def fromsources(sources, topic, site: Site, n=cfg.POOL_SIZE):
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global FEEDS, ARTICLES
    ensure_globals(site, topic)
    jobs = []
    logger.info("Starting to collect articles/feeds from %d sources.", len(sources))
    for entry in sources:
        url = entry.get("url")
        if not url:
            continue
        logger.info("Fetching articles/feeds from %s", url)
        j = sched.apply(parsesource, url, topic, site)
        jobs.append(j)
    n_jobs = len(jobs)
    for n, j in enumerate(jobs):
        logger.info("Waiting for job: %d/%d.", n, n_jobs)
        j.wait(cfg.REQ_TIMEOUT * 2)

    logger.info("Source parsing Done")
    FEEDS[site.name][topic] = ut.dedup(FEEDS)
    logger.info(
        "Found %d feeds and %d articles in %d sources.",
        len(FEEDS[site.name][topic]),
        len(ARTICLES[site.name][topic]),
        len(sources),
    )
    return (ARTICLES[site.name][topic], FEEDS[site.name][topic])


def fromfeeds(sources, topic, site: Site, n=cfg.POOL_SIZE) -> List:
    """Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE."""
    global ARTICLES
    ensure_globals(site, topic)
    jobs = []
    url = ""
    for url in sources:
        if not url or not isinstance(url, str):
            continue
        logger.info("Fetching articles from %s", url)
        j = sched.apply(parsearticle, url, topic, site)
        jobs.append(j)
    for n, j in enumerate(jobs):
        j.wait(cfg.REQ_TIMEOUT * 2)
        logger.info("Waiting for job: %s.", n)

    logger.info("Articles parsing Done")
    logger.info(
        "Found %d articles in %d sources.",
        len(ARTICLES[site.name][topic]),
        len(sources),
    )
    return ARTICLES[site.name][topic]


def processfeed(f):
    try:
        pf = parsefeed(f)
        if not pf["entries"]:
            return []
    except:
        return False
