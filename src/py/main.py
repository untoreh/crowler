#!/usr/bin/env python3

import json
import os
import shutil
import argparse
import time
from pathlib import Path

from searx.shared.shared_simple import schedule

import config as cfg
import contents as cnt
import sources
import utils as ut
import scheduler
import blacklist
from log import logger
from datetime import datetime


def get_kw_batch(topic):
    """Get a batch of keywords to search and update lists accordingly."""
    subdir = cfg.TOPICS_DIR / topic
    kwlist = subdir / "list.txt"
    assert os.path.exists(kwlist)

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
        batch.append(kws.pop())

    ut.save_file("\n".join(kws), queue, root=None, ext="txt", as_json=False, mode="w")
    return batch


def run_sources_job(topic):
    """
    Run one iteration of the job to find source links from keywords. Sources are used to find articles.
    This function should never be called directly, instead `parse1` should use it when it runs out of sources.
    """
    logger.info("Getting kw batch...")
    scheduler.initPool()
    batch = get_kw_batch(topic)
    root = cfg.TOPICS_DIR / topic / "sources"
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
            if kw in jobs:
                kwjobs = jobs[kw]
                for (n, j) in enumerate(kwjobs):
                    if j.ready():
                        res = j.get()
                        results[kw].extend(res)
                        ready[kw] += 1
            if ready[kw] == 3 and ready[kw] >= 0:
                kwresults = blacklist.exclude_blacklist_sources(results[kw])
                kwresults = sources.dedup_results(kwresults)
                if kwresults:
                    ut.save_file(kwresults, ut.slugify(kw), root=root)
                del jobs[kw]
                ready[kw] = -1
                logger.debug(f"Processed kw: {kw}")
            time.sleep(0.25)

def get_kw_sources(topic, remove=cfg.REMOVE_SOURCES):
    root = cfg.TOPICS_DIR / topic / "sources"
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


def ensure_sources(topic):
    sources = get_kw_sources(topic)
    if not sources:
        logger.info("No sources remaining, fetching new sources...")
        run_sources_job(topic)
        sources = get_kw_sources(topic)
    if not sources:
        raise ValueError("Could not ensure sources for topic %s.", topic)
    return sources


def run_parse1_job(topic):
    """
    Run one iteration of the job to find articles and feeds from source links.
    """
    try:
        sources = ensure_sources(topic)
    except ValueError:
        logger.warning("Couldn't find sources for topic %s.", topic)
        return None

    arts, feeds = cnt.fromsources(sources, topic)
    topic_path = cfg.TOPICS_DIR / Path(topic)
    sa = sf = None

    if arts:
        logger.info("%s: Saving %d articles.", topic, len(arts))
        sa = ut.save_zarr(arts, k=ut.ZarrKey.articles, root=topic_path)
    else:
        logger.info("%s: No articles found.", topic)

    if feeds:
        logger.info("%s: Saving %d articles.", topic, len(feeds))
        sf = ut.save_zarr(feeds, k=ut.ZarrKey.feeds, root=topic_path)
    else:
        logger.info("%s: No feeds found.", topic)

    return (sa, sf)


def get_feeds(topic, n=3, resize=True):
    while True:
        z = ut.load_zarr(k=ut.ZarrKey.feeds, root=cfg.TOPICS_DIR / topic)
        if len(z) > 0:
            break
        else:
            logger.info("No feeds found to parse for topic %s, searching new ones", topic)
            run_parse1_job(topic)
    if len(z) < n:
        if resize:
            z.resize(0)
        return z[:]
    else:
        f = z[-n:]
        if resize:
            z.resize(len(z) - n)
        return f


def run_parse2_job(topic):
    """
    Run one iteration of the job to find articles from feed links.
    """
    feed_links = get_feeds(topic, 3)
    if not feed_links:
        logger.warning("Couldn't find feeds for topic %s", topic)
        return None
    logger.info("Search %d feeds for articles...", len(feed_links))
    articles = cnt.fromfeeds(feed_links)
    a = None
    if articles:
        logger.info("%s: Saving %d articles.", topic, len(articles))
        a = ut.save_zarr(
            articles, k=ut.ZarrKey.articles, root=cfg.TOPICS_DIR / Path(topic)
        )
    else:
        logger.info("%s: No articles were found queued.", topic)
    return a

def run_server(topics):
    while True:
        pass

JOBS_MAP = {
    "sources": run_sources_job,
    "parse1": run_parse1_job,
    "parse2": run_parse2_job,
}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-job", help="What kind of job to perform", default="parse1")
    parser.add_argument("-topics", help="The topics to fetch articles for.", default="")
    parser.add_argument("-workers", help="How many workers.", default=cfg.POOL_SIZE)
    parser.add_argument("-server", help="Start the server.", default=cfg.POOL_SIZE)
    args = parser.parse_args()
    cfg.POOL_SIZE = int(args.workers)
    topics = args.topics.split(",")
    if topics:
        for tp in topics:
            JOBS_MAP[args.job](tp)
    else:
        raise ValueError("Pass a `-topics` as argument to run a job.")
