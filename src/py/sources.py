import config as cfg

from retry import retry
import sys, os
from multiprocessing.pool import ThreadPool
from random import shuffle, choice
from log import logger, LoggerLevel, logger_level

from proxies import set_socket_timeout
import scheduler as sched
from blacklist import exclude_blacklist

set_socket_timeout(100)

from searx.search import SearchQuery, EngineRef
from searx import search

# the searx.search module has a variable named `processors`
# import importlib

# proc = importlib.import_module("searx.search.processors", package="searx")

# Path params to disable ssl verification
# online_req_params = proc.online.default_request_params()


# def default_request_params():
#     online_req_params["verify"] = False
#     return online_req_params


# proc.online.default_request_params = default_request_params

ENGINES = [
    "google",
    "reddit",
    "startpage",
    "duckduckgo",
    "bing",
    "onesearch",
    "qwant",
    "digg",
]
N_ENGINES = len(ENGINES)
R_ENGINES = []

def get_engine():
    engines = ENGINES.copy()
    shuffle(engines)
    for e in engines:
        yield e

def get_engine_params(engine):
    params = {
        "shortcut": engine,
        "engine": engine,
        "name": engine,
        "timeout": cfg.REQ_TIMEOUT,
        "categories": "general",
    }
    if cfg.PROXIES_ENABLED:
        params["network"] = {"verify": False, "proxies": cfg.STATIC_PROXY_EP}
    return params


ENGINES_PARAMS = [get_engine_params(engine) for engine in ENGINES]
search.initialize(settings_engines=ENGINES_PARAMS)

@retry(tries=cfg.SRC_MAX_TRIES, delay=1, backoff=3.0, logger=None)
def single_search(kw, engine, pages=1, timeout=cfg.REQ_TIMEOUT, category=""):
    res = []
    for p in range(pages):
        s = SearchQuery(kw, [EngineRef(engine, category)], timeout_limit=timeout, pageno=p)
        q = search.Search(s).search()
        res = q.get_ordered_results()
        if len(res) > 0:
            res.extend(res)
    return res

def try_search(*args, **kwargs):
    logger.info("Processing single search...")
    with LoggerLevel():
        try:
            return single_search(*args, **kwargs)
        except Exception as e:
            exc = e
    logger.debug("Caught search exception %s", type(exc))
    return []


def dedup_results(results):
    all_results = []
    urls = set()
    for item in results:
        u = item["url"]
        if u not in urls:
            urls.add(u)
            all_results.append({k: item[k] for k in ("url", "parsed_url", "title")})
    return all_results


def fromkeyword(
    keyword="trending",
    verbose=False,
    n_engines=1,
):
    """
    `n_engines`: How many search engines to query.
    """
    try:
        engines = ENGINES.copy()
        shuffle(engines)
        logger.info("Finding sources for keyword: %s", keyword)
        assert isinstance(cfg.POOL_SIZE, int)
        res = sched.POOL.starmap(try_search, [(keyword, engines[n], 1) for n in range(cfg.POOL_SIZE)])
    except KeyboardInterrupt:
        print("Caught KB interrupt.")
        sched.POOL.close()
        print("Terminating pool...")
        sched.POOL.terminate()
        # shut up requests in flight warning
        sys.stdout = os.devnull
        sys.stderr = os.devnull
        with LoggerLevel(level=None):
            exit()
    res = dedup_results(res)
    if verbose:
        print(res)
    return res

def fromkeyword_async(
    keyword="trending",
    n_engines=1,
):
    """
    `n_engines`: How many search engines to query.
    """
    logger.info("Finding sources for keyword: %s", keyword)
    n = 0
    kwjobs = []
    for egn in get_engine():
        n += 1
        if n > n_engines:
            break
        j = sched.apply(try_search, keyword, egn, 1)
        kwjobs.append(j)
    return kwjobs

def print_results(res):
    for r in res:
        print(r.get())
