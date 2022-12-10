#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import time
import traceback as tb
from typing import List, Union
import zarr as za
from numpy import ndarray

import blacklist
import config as cfg
import contents as cnt
import proxies_pb as pb
import scheduler as sched
import sources  # NOTE: searx has some namespace conflicts with google.ads, initialize after the `adwords_keywords` module
import topics as tpm
import utils as ut
from log import logger
from sites import Job, Site, Topic


def get_kw_batch(site: Site, topic):
    """Get a batch of keywords to search and update lists accordingly."""
    subdir = site.topic_dir(topic)
    kwlist = subdir / "list.txt"
    assert kwlist.exists(), f"kwbatch: {kwlist} was not found on storage"

    queue = subdir / "queue"
    kws = ut.read_file(queue)
    # Since we remove processed kws from queue, eventually the file becomes empty
    if not kws or len(kws[0]) < 4:
        # When no keywords are in queue, remake queue from original list
        shutil.copyfile(kwlist, f"{queue}.txt")
        kws = ut.read_file(queue)
        assert kws is not None and len(kws[0]) > 4

    kws = set(kws)
    batch = []
    for _ in range(cfg.KW_SAMPLE_SIZE):
        if kws:
            batch.append(kws.pop())

    ut.save_file("\n".join(kws), queue, root=None, ext="txt", as_json=False, mode="w")
    return batch


def run_sources_job(site: Site, topic):
    """
    Run one iteration of the job to find source links from keywords. Sources are used to find articles.
    This function should never be called directly, instead `parse` should use it when it runs out of sources.
    """
    logger.info("Getting kw batch...")
    sched.initPool()
    batch = get_kw_batch(site, topic)
    root = site.topic_sources(topic)
    results = dict()
    jobs = dict()
    ready = dict()
    for (n, kw) in enumerate(batch):
        logger.info("Keywords: %d/%d.", n, cfg.KW_SAMPLE_SIZE)
        kwjobs = sources.fromkeyword_async(kw, n_engines=3)
        jobs[kw] = kwjobs
        results[kw] = []
        ready[kw] = 0
    start = time.time()
    while len(jobs) > 0:
        logger.debug(f"Remaining kws: {len(jobs)}")
        if time.time() - start > cfg.KW_SEARCH_TIMEOUT:
            logger.debug("Timing out kw search..")
            break
        for kw in ready.keys():
            if not kw:
                continue
            if kw in jobs:
                kwjobs = jobs[kw]
                for (n, j) in enumerate(kwjobs):
                    if j.ready():
                        res = j.get()
                        results[kw].extend(res)
                        ready[kw] += 1
            if ready[kw] == 3 and ready[kw] >= 0:
                kwresults = blacklist.exclude_blacklist_sources(
                    site, results[kw], blacklist.exclude_sources
                )
                kwresults = sources.dedup_results(kwresults)
                if kwresults:
                    ut.save_file(kwresults, ut.slugify(kw), root=root)
                del jobs[kw]
                ready[kw] = -1
                logger.debug(f"Processed kw: {kw}")
            time.sleep(0.25)


def get_kw_sources(site: Site, topic, remove=cfg.REMOVE_SOURCES):
    root = site.topic_sources(topic)
    for _, _, files in os.walk(root):
        for f in files:
            if f not in ("list.txt", "queue.txt", "lsh.json"):
                if f.startswith("."):
                    continue
                results_path = root / f
                res = ut.read_file(results_path, ext=None)
                assert type(res) is str
                if remove:
                    os.remove(results_path)
                kws = json.loads(res)
                if not kws and not remove:
                    logger.debug("Removing empty sources file %s.", os.path.basename(f))
                    os.remove(results_path)
                    continue
                return kws


def ensure_sources(site, topic):
    sources = get_kw_sources(site, topic)
    if not sources:
        logger.info("No sources remaining, fetching new sources...")
        run_sources_job(site, topic)
        sources = get_kw_sources(site, topic)
    if not sources:
        raise ValueError("Could not ensure sources for topic %s.", topic)
    return sources

SCRAPE_LOG = cfg.DATA_DIR / "scrape_logs.txt"
def log_parsed(s):
    with open(SCRAPE_LOG, "a+") as f:
        f.write(s)

def run_parse_job(site, topic):
    """
    Run one iteration of the job to find articles and feeds from source links.
    """
    try:
        sources = ensure_sources(site, topic)
    except ValueError:
        logger.warn(
            "Couldn't find sources for topic %s, site: %s.", topic, site.name
        )
        return None

    try:
        logger.info("Parsing %d sources...for %s:%s", len(sources), topic, site.name)
        arts, feeds = cnt.fromsources(sources, topic, site)
        topic_path = site.topic_dir(topic)
    except:
        logger.warn("parse job failed. \n %s", tb.format_exc())

    try:
        if arts:
            logger.info("%s@%s: Saving %d articles.", topic, site.name, len(arts))
            ut.save_zarr(arts, k=ut.ZarrKey.articles, root=topic_path)
            site.update_article_count(topic)
        else:
            logger.info("%s@%s: No articles found.", topic, site.name)
    except:
        logger.warn("parse job failed. \n %s", tb.format_exc())

    try:
        if feeds:
            logger.info("%s@%s: Saving %d articles.", topic, site.name, len(feeds))
            ut.save_zarr(feeds, k=ut.ZarrKey.feeds, root=topic_path)
        else:
            logger.info("%s@%s: No feeds found.", topic, site.name)
    except:
        logger.warn("parse job failed. \n %s", tb.format_exc())

    log_parsed(f"Found {len(arts)} articles and {len(feeds)} feeds for topic {topic}.\n")
    return (arts, feeds)


def get_feeds(site: Site, topic, n=3, resize=True) -> Union[List, ndarray]:
    z = site.load_feeds(topic)
    if len(z) == 0:
        return []
    assert isinstance(z, za.Array)
    if len(z) < n:
        feeds = z[:]
        if resize:
            z.resize(0)
        return feeds
    else:
        feeds = z[-n:]
        if resize:
            z.resize(len(z) - n)
        return feeds


def run_feed_job(site: Site, topic):
    """
    Run one iteration of the job to find articles from feed links.
    """
    feed_links = get_feeds(site, topic, 3)
    if not len(feed_links):
        logger.warning("Couldn't find feeds for topic %s@%s", topic, site.name)
        return None
    logger.info("Search %d feeds for articles...", len(feed_links))
    articles = cnt.fromfeeds(feed_links, topic, site)
    if len(articles):
        logger.info("%s@%s: Saving %d articles.", topic, site.name, len(articles))
        ut.save_zarr(articles, k=ut.ZarrKey.articles, root=site.topic_dir(topic))
        site.update_article_count(topic)
    else:
        logger.info("%s@%s: No articles were found queued.", topic, site.name)
    return articles


def new_topic(site: Site, force=False):
    last_topic = tpm.get_last_topic(site)
    if force or time.time() - last_topic["time"] > cfg.NEW_TOPIC_FREQ:
        newtopic = tpm.new_topic(site)
        logger.info("topics: added new topic %s", newtopic)

def site_loop(site: Site, throttle=5):
    site.load_topics()
    sched.initPool()
    backoff = 0
    while True:
        pb.proxy_sync_forever(cfg.PROXIES_FILES, cfg.PROXIES_DIR)
        try:
            topics = site.sorted_topics(key=Topic.UnpubCount)
            # print(h.heap())
            try:
                for topic in topics:
                    if site.is_paste_interval(Job.parse, topic):
                        run_parse_job(site, topic)
            except:
                logger.warn("parse job failed. \n %s", tb.format_exc())
            try:
                for topic in topics:
                    if site.is_paste_interval(Job.feed, topic):
                        run_feed_job(site, topic)
            except:
                logger.warn("feed job failed. \n %s", tb.format_exc())
            try:
                if site.new_topics_enabled:
                    new_topic(site)
            except:
                logger.warn("new topics  failed. \n %s", tb.format_exc())
            try:
                if site.is_paste_interval(Job.reddit):
                    site.reddit_submit()
            except:
                logger.warn("reddit failed. \n %s", tb.format_exc())
            try:
                if site.is_paste_interval(Job.twitter):
                    site.tweet()
            except:
                logger.warn("twitter failed. \n %s", e)
            try:
                if site.is_paste_interval(Job.facebook):
                    site.facebook_post()
            except:
                logger.warn("facebook failed. \n %s", tb.format_exc())
            time.sleep(throttle)
        except:
            logger.warning(f"{tb.format_exc()} (site: {site.name})")
            backoff += 1
            time.sleep(backoff)


def run_server(sites):
    # from guppy import hpy
    # h = hpy()
    if len(sites) == 0:
        logger.warn("no sites provided.")
        return
    sched.initPool()
    jobs = {}
    for sitename in sites:
        site = Site(sitename)
        jobs[site] = sched.apply(site_loop, site)
    # NOTE: this runs indefinitely
    while True:
        for (site, j) in jobs.items():
            if j.ready():
                jobs[site] = sched.apply(site_loop, site)
        time.sleep(5)


JOBS_MAP = {
    "sources": run_sources_job,
    "parse": run_parse_job,
    "feed": run_feed_job,
    "newtopic": new_topic,
}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-job", help="What kind of job to perform", default="parse")
    parser.add_argument("-sites", help="The sites to run the server for.", default="")
    parser.add_argument("-workers", help="How many workers.", default=cfg.POOL_SIZE)
    parser.add_argument("-server", help="Start the server.", default=False)
    parser.add_argument("-topic", help="Specify a single topic.", default="")
    args = parser.parse_args()
    cfg.POOL_SIZE = int(args.workers)
    sites = args.sites.split(",")
    if args.server:
        assert len(sites) > 0 and sites[0] != "", "Invalid sites list."
        run_server(sites)
    else:
        assert (
            len(sites) == 1
        ), "Can only execute jobs on a single site:topic combination."
        st = Site(sites[0])
        if args.topic != "":
            JOBS_MAP[args.job](st, args.topic)
        else:
            assert args.job == "newtopic", "Job not understood."
            JOBS_MAP[args.job](st, force=True)
