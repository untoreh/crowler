import os
import sys
from random import shuffle

from retry import retry
from searx import search
from searx.search import EngineRef, SearchQuery

import config as cfg
import proxies_pb as pb
import scheduler as sched
import translator as tr
from log import LoggerLevel, logger

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
    "qwant",
    "gigablast",
    "unsplash",
]
ENGINES_IMG = [
    "google_images",
    "duckduckgo_images",
    "bing_images",
    "unsplash",
    "flickr_noapi",
    "frinkiac",
    "openverse",
]
# ENGINES_IMG_ONLY = {"flickr_noapi", "frinkiac", "openverse"}
""
N_ENGINES = len(ENGINES)
N_ENGINES_IMG = len(ENGINES_IMG)
R_ENGINES = []


def get_engine():
    engines = ENGINES.copy()
    shuffle(engines)
    for e in engines:
        yield e


def get_engine_img():
    engines = [e.split("_")[0] for e in ENGINES_IMG.copy()]
    shuffle(engines)
    for e in engines:
        yield e


def get_engine_params(engine):
    cats = "general" if engine in ENGINES else "images"
    params = {
        "shortcut": engine,
        "engine": engine,
        "name": engine.split("_")[0],
        "timeout": cfg.REQ_TIMEOUT,
        "categories": cats,
    }
    if False:  # cfg.PROXIES_ENABLED:
        params["network"] = {
            "verify": False,
            "proxies": pb.STATIC_PROXY_EP,
            "retries": 3,
            "retry_on_http_error": True,
            "max_redirects": 30,
        }
    return params


ENGINES_INITIALIZED = False

def ensure_engines():
    if not ENGINES_INITIALIZED:
        ENGINES_PARAMS = [get_engine_params(engine) for engine in ENGINES]
        search.initialize(settings_engines=ENGINES_PARAMS)
        ENGINES_PARAMS_IMG = [get_engine_params(engine) for engine in ENGINES_IMG]
        search.initialize(settings_engines=ENGINES_PARAMS_IMG)
        ENGINES_INITIALIZED = True

@retry(tries=cfg.SRC_MAX_TRIES, delay=1, backoff=3.0, logger=None)
def single_search(
    kw, engine, pages=1, lang="all", timeout=cfg.REQ_TIMEOUT, category=""
):
    res = []
    for p in range(pages):
        s = SearchQuery(
            kw,
            [EngineRef(engine, category)],
            timeout_limit=timeout,
            pageno=p,
            lang=lang,
        )
        with pb.http_opts(proxy="auto"):
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


def fromkeyword(keyword="trending", verbose=False, filter_lang=False):
    """
    `n_engines`: How many search engines to query.
    """
    try:
        ensure_engines()
        engines = ENGINES.copy()
        shuffle(engines)
        logger.info("Finding sources for keyword: %s", keyword)
        assert isinstance(cfg.POOL_SIZE, int)
        kwlang = tr.detect(keyword) if filter_lang else "all"
        res = sched.POOL.starmap(
            try_search, [(keyword, engines[n], 1, kwlang) for n in range(cfg.POOL_SIZE)]
        )
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


def fromkeyword_async(keyword="trending", n_engines=1, filter_lang=False):
    """
    `n_engines`: How many search engines to query.
    """
    logger.info("Finding sources for keyword: %s", keyword)
    n = 0
    kwjobs = []
    kwlang = tr.detect(keyword) if filter_lang else "all"
    for egn in get_engine():
        n += 1
        if n > n_engines:
            break
        j = sched.apply(try_search, keyword, egn, 1, kwlang)
        kwjobs.append(j)
    return kwjobs


from typing import NamedTuple


class Img(NamedTuple):
    title: str
    url: str
    origin: str


def get_images(kw, maxiter=3, min_count=1, raw=False):
    """"""
    ensure_engines()
    results = []
    itr = 0
    try:
        for egn in get_engine_img():
            response = single_search(
                kw,
                egn,
                pages=1,
                lang="all",
                timeout=cfg.REQ_TIMEOUT,
                category="images",
            )
            results.extend(response)
            if len(results) > min_count or itr > maxiter:
                break
            itr += 1
    finally:
        return (
            results
            if raw
            else [
                Img(title=r["title"], url=r["img_src"], origin=r["url"])
                for r in results
            ]
        )


def print_results(res):
    for r in res:
        print(r.get())
