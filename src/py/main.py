#!/usr/bin/env python3

import json
import os
import shutil
import argparse
from pathlib import Path

import config as cfg
import contents as cnt
import sources
import utils as ut
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
    batch = get_kw_batch(topic)
    for kw in batch:
        logger.info("Finding sources for keyword %s .", kw)
        results = sources.fromkeyword(kw, n_engines=3)
        if results:
            ut.save_file(results, ut.slugify(kw), root=cfg.TOPICS_DIR / topic)


def get_kw_sources(topic, remove=True):
    root = cfg.TOPICS_DIR / topic
    for _, _, files in os.walk(root):
        for f in files:
            if f not in ("list.txt", "queue.txt"):
                if f.startswith("."):
                    continue
                results_path = root / f
                res = ut.read_file(results_path, ext=None)
                assert type(res) is str
                if remove:
                    os.remove(results_path)
                kws = json.loads(res)
                if not kws:
                    logger.debug("Removing empty sources file %s.", os.path.basename(f))
                    os.remove(results_path)
                    continue
                return kws


def ensure_sources(topic):
    sources = get_kw_sources(topic, remove=False)
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

    arts, feeds = cnt.fromsources(sources)
    topic_path = cfg.TOPICS_DIR / Path(topic)
    sa = sf = None

    if args:
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
    z = ut.load_zarr(k=ut.ZarrKey.feeds, root=cfg.TOPICS_DIR / topic)
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


JOBS_MAP = {
    "sources": run_sources_job,
    "parse1": run_parse1_job,
    "parse2": run_parse2_job,
}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-job", help="What kind of job to perform", default="parse1")
    parser.add_argument("-topic", help="The topic to fetch articles for.", default="")
    parser.add_argument("-workers", help="How many workers.", default=cfg.POOL_SIZE)
    args = parser.parse_args()
    cfg.POOL_SIZE = args.workers
    if args.topic:
        JOBS_MAP[args.job](args.topic)
    else:
        raise ValueError("Pass a `-topic` as argument to run a job.")
