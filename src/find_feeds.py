import feedfinder2 as ff2
from multiprocessing.pool import ThreadPool
from threading import Semaphore
import requests
import random
import config as cfg
import json
import os
import warnings
warnings.simplefilter("ignore")

FEEDS = []
PROCESSED_IDS = []

cfg.PROXY_DICT = {}
# overwrite feedfinder get_feed to support proxies
def get_feed(self, url):
    try:
        r = requests.get(url, headers={"User-Agent": self.user_agent}, proxies=cfg.PROXY_DICT)
    except:
        return None
    return r.text
ff2.FeedFinder.get_feed = get_feed

if not os.path.exists(cfg.SRC_FILE):
    raise RuntimeError(f"No source file ({cfg.SRC_FILE}) found")

def load_sources():
    global sources, n_sources, sources_history
    with open(cfg.SRC_FILE) as f:
        sources = json.load(f)
        n_sources = len(sources)

    if os.path.exists(cfg.SRC_HISTORY_FILE):
        with open(cfg.SRC_HISTORY_FILE) as f:
            sources_history = json.load(f)
    else:
        sources_history = []

def fetch_feeds(url):
    f = ff2.find_feeds(url)
    FEEDS.extend(f)

""" Create list of feeds from a subset of links found in the source file, according to SRC_SAMPLE_SIZE. """
def execute(verbose=False, remove_sources=False):
    load_sources()

    pool = ThreadPool(processes=cfg.POOL_SIZE)
    sem = Semaphore(cfg.POOL_SIZE)
    sem_release = lambda *_: sem.release()

    while sem.acquire(blocking=True) and len(FEEDS) < cfg.SRC_SAMPLE_SIZE:
        src_idx = random.randint(1, n_sources)
        url = sources[src_idx]
        pool.apply_async(fetch_feeds, args=(url,), callback=sem_release)
        PROCESSED_IDS.append(src_idx)

    with open(cfg.FEEDS_FILE, "w") as f:
        json.dump(FEEDS, f)

    if remove_sources:
        for idx in sorted(PROCESSED_IDS, reverse=True):
            del sources[idx]
        with open(cfg.SRC_FILE, "w") as f:
            json.dump(sources, f)

    if verbose: print(FEEDS)
