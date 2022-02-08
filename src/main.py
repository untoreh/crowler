#!/usr/bin/env python3

import utils as ut
import config as cfg
import shutil
import os
from random import choices
import find_sources
from pathlib import Path

def get_kw_batch(topic):
    """Get a batch of keywords to search and update lists accordingly."""
    subdir = cfg.TOPICS_DIR / topic
    kwlist = subdir / "list.txt"
    assert os.path.exists(kwlist)

    queue = subdir / "queue.txt"
    kws = ut.read_file(queue)
    # Since we remove processed kws from queue, eventually the file becomes empty
    if not kws:
        # When no keywords are in queue, remake queue from original list
        shutil.copyfile(kwlist, queue)
        kws = ut.read_file(queue)
        assert kws is not None

    kws = set(kws)
    batch = []
    for _ in range(cfg.KW_SAMPLE_SIZE):
        batch.append(kws.pop())

    ut.save_file("\n".join(kws), queue, root=cfg.DATA_DIR, as_json=False, mode="w")
    return batch

def run_sources_job(kwlist):
    """
    Run one iteration of the job to find source links from keywords. Sources are used to find articles.
    """
    batch = get_kw_batch(kwlist)
    for kw in batch:
        results = find_sources.execute(kw, n_engines=3, save=False)
        ut.save_file(results, ut.slugify(kw), root=cfg.KW_DIR / kwlist)
