#!/usr/bin/env python3

import json
import os
import shutil
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


@retry(ValueError, tries=3)
def ensure_sources(topic):
    sources = get_kw_sources(topic)
    if not sources:
        logger.info("No sources remaining, fetching new sources...")
        run_sources_job(topic)
        sources = get_kw_sources(topic)
    if not sources:
        raise ValueError()
    return sources


def run_articles_job(topic):
    """
    Run one iteration of the job to find articles from source links.
    """
    sources = ensure_sources(topic)

    arts, feeds = cnt.fromsources(sources)
    tp_path = Path(topic)
    arts_path = tp_path / "articles"
    job_id = str(int(datetime.now().timestamp()))
    logger.info("Saving %d articles to %s.", len(arts), os.path.realpath(arts_path))
    sa = ut.save_file(arts, arts_path / job_id, root=cfg.TOPICS_DIR, as_json=True)

    feeds_path = tp_path / "feeds"
    logger.info("Saving %d articles to %s.", len(feeds), os.path.realpath(feeds_path))
    sf = ut.save_file(feeds, feeds_path / job_id, root=cfg.TOPICS_DIR, as_json=True)
    return (sa, sf)


def run(topic):
    run_articles_job(topic)
