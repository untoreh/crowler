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
from utils import logger
from datetime import datetime
from retry import retry


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
    """
    batch = get_kw_batch(topic)
    for kw in batch:
        results = sources.fromkeyword(kw, n_engines=3, save=False)
        ut.save_file(results, ut.slugify(kw), root=cfg.TOPICS_DIR / topic)


def get_kw_sources(topic, remove=True):
    root = cfg.TOPICS_DIR / topic
    for _, _, files in os.walk(root):
        for f in files:
            if f not in ("list.txt", "queue.txt"):
                results_path = root / f
                res = ut.read_file(results_path, ext=None)
                if remove:
                    os.remove(results_path)
                assert type(res) is str
                return json.loads(res)


def ensure_sources(topic):
    sources = get_kw_sources(topic)
    if not sources:
        logger.info("No sources remaining, fetching new sources...")
        run_sources_job(topic)
        sources = get_kw_sources(topic)
    if not sources:
        raise ValueError()
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
    tp_path = Path(topic)
    sa = sf = None

    if args:
        arts_path = tp_path / "articles"
        logger.info("Saving %d articles to %s.", len(arts), os.path.realpath(arts_path))
        sa = ut.save_zarr(arts, root=cfg.TOPICS_DIR / arts_path)
    else:
        logger.info("No articles were found for %s.", topic)

    if feeds:
        feeds_path = tp_path / "feeds"
        logger.info(
            "Saving %d articles to %s.", len(feeds), os.path.realpath(feeds_path)
        )
        sf = ut.save_zarr(feeds, k=ut.ZarrKey.feeds, root=cfg.TOPICS_DIR / feeds_path)
    else:
        logger.info("No feeds were found for %s.", topic)

    return (sa, sf)


def get_feeds(topic, n=3):
    feeds_path = Path(topic) / "feeds"
    z = ut.load_zarr(k=ut.ZarrKey.feeds, root=cfg.TOPICS_DIR / feeds_path)
    if len(z) < n:
        return z[:]
    else:
        f = z[0:n]
        z.resize(len(z) - n)
        return f


def run_parse2_job(topic):
    """
    Run one iteration of the job to find articles from feed links.
    """
    feed_links = get_feeds(topic, 3)
    articles = cnt.fromfeeds(feed_links)
    a = None
    if articles:
        arts_path = Path(topic) / "articles"
        logger.info(
            "Saving %d articles to %s.", len(articles), os.path.realpath(arts_path)
        )
        a = ut.save_zarr(articles, k=ut.ZarrKey.articles, root=cfg.TOPICS_DIR / arts_path)
    return a


JOBS_MAP = {
    "sources": run_sources_job,
    "articles": run_parse1_job,
    "publish": run_parse2_job,
}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-job", help="What kind of job to perform", default="articles")
    parser.add_argument("-topic", help="The topic to fetch articles for.", default="")
    args = parser.parse_args()
    if args.topic:
        JOBS_MAP[args.job](args.topic)
    else:
        raise ValueError("Pass a `-topic` as argument to run a job.")
