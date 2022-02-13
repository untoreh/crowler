import config as cfg

from retry import retry
from requests import get
from multiprocessing.pool import ThreadPool
import json
from random import shuffle
from utils import logger

from proxies import set_socket_timeout

set_socket_timeout(100)

from searx.search import SearchQuery, EngineRef
from searx import search

RESULTS = dict()
ENGINES = [
    "google",
    "bing",
    "qwant",
    "reddit",
    "onesearch",
    "digg",
    "duckduckgo",
    "startpage",
]


def get_engine_params(engine):
    params = {
        "shortcut": engine,
        "engine": engine,
        "name": engine,
        "timeout": cfg.REQ_TIMEOUT,
        "categories": "general",
    }
    if cfg.PROXIES_ENABLED:
        params["network"] = {"proxies": cfg.STATIC_PROXY_EP}
    return params


ENGINES_PARAMS = [get_engine_params(engine) for engine in ENGINES]
search.initialize(settings_engines=ENGINES_PARAMS)


@retry(tries=cfg.SRC_MAX_TRIES, delay=1, backoff=3.0)
def single_search(kw, engine, pages=1, timeout=cfg.REQ_TIMEOUT, category=""):
    RESULTS[engine] = []
    for p in range(pages):
        s = SearchQuery(kw, [EngineRef(engine, category)], timeout_limit=timeout)
        q = search.Search(s).search()
        res = q.get_ordered_results()
        if len(res) == 0:
            if p == 0:
                raise ValueError(engine)
        else:
            RESULTS[engine].extend(res)


def try_search(*args, **kwargs):
    try:
        single_search(*args, **kwargs)
    except:
        pass


def dedup_results():
    all_results = []
    urls = set()
    for r in RESULTS.values():
        for item in r:
            u = item["url"]
            if u not in urls:
                urls.add(u)
                all_results.append({k: item[k] for k in ("url", "parsed_url", "title")})
    return all_results


def fromkeyword(
    keyword="trending", verbose=False, n_engines=1, n_workers=cfg.POOL_SIZE, save=False
):
    """
    `n_engines`: How many search engines to query.
    `n_workers`: How many queries to run in parallel.
    """
    pool = ThreadPool(processes=n_workers)
    try:
        engines = ENGINES.copy()
        shuffle(engines)
        logger.info("Finding sources for keyword: %", keyword)
        pool.starmap(try_search, [(keyword, engines[n], 1) for n in range(n_workers)])
    except KeyboardInterrupt:
        pass
    res = dedup_results()
    if save:
        with open(cfg.SRC_FILE, "w") as f:
            json.dump(res, f)
    if verbose:
        print(res)
    return res
