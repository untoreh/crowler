import copy
import os
import sys
from random import shuffle, randint
from time import sleep

import searx
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

ENGINES = ["google", "reddit", "startpage", "duckduckgo", "bing"]
ENGINES_IMG = [
    "google_images", # lang is not initialized problem
    "duckduckgo_images",
    "bing_images",
    "unsplash",
    "flickr_noapi",
    "frinkiac",
    # "openverse", # error 400
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


def img_engine_name(engine):
    return engine.replace("_", "-")


def get_engine_img():
    engines = [img_engine_name(e) for e in ENGINES_IMG.copy()]
    shuffle(engines)
    for e in engines:
        yield e


searx_proxies = {"http": pb.STATIC_PROXY_EP, "https": pb.STATIC_PROXY_EP}
def switch_searx_proxies():
    searx_proxies["http"] = pb.get_proxy(static=False, http=True)
    searx_proxies["https"] = pb.get_proxy(static=False, http=False)

def get_engine_params(engine, cat=None):
    cats = cat if cat is not None else "general" if engine in ENGINES else "images"
    params = {
        "shortcut": engine if cats != "images" else f"{engine[0:2]}i",
        # "shortcut": engine,
        "engine": engine,
        # "name": engine.split("_")[0],
        "name": img_engine_name(engine),
        "timeout": cfg.REQ_TIMEOUT,
        "categories": cats,
    }
    params["network"] = {
        "verify": False,
        "proxies": searx_proxies,
        "retries": 3,
        "retry_on_http_error": True,
        "max_redirects": 30,
    }
    return params


ENGINES_INITIALIZED = False


def ensure_engines(force=False):
    global ENGINES_INITIALIZED
    if force or not ENGINES_INITIALIZED:
        print("Ensuring searx engines are loaded...")
        searx.network.network.NETWORKS.clear()
        searx.search.PROCESSORS.clear()
        searx.engines.engines.clear()
        settings = [get_engine_params(engine) for engine in ENGINES]
        settings.extend([get_engine_params(engine) for engine in ENGINES_IMG])
        search.initialize(settings_engines=settings)
        # fix for non initialized langs
        eng = searx.engines.engines.get("google-images")
        if not eng is None and not eng.supported_languages:
            if not eng.supported_languages:
                eng.supported_languages = eng.fetch_supported_languages()
        ENGINES_INITIALIZED = True


def single_search(
    kw,
    engine,
    pages=1,
    lang="all",
    timeout=cfg.REQ_TIMEOUT,
    category="general",
    depth=1,
):
    res = []
    logger.info(f"Processing single search, engine: {engine}")
    for p in range(pages):
        with pb.http_opts(proxy=depth):
            s = SearchQuery(
                kw,
                [EngineRef(engine, category)],
                timeout_limit=timeout,
                pageno=p,
                lang=lang,
            )
            q = search.Search(s).search()
        if len(q.unresponsive_engines) > 0:
            raise ValueError(q.unresponsive_engines.pop())
        q_res = q.get_ordered_results()
        if len(q_res) > 0:
            res.extend(q_res)
    return res


def try_search(*args, depth=1, backoff=0.3, max_tries=4, **kwargs):
    ensure_engines()
    switch_searx_proxies()
    try:
        return single_search(*args, **kwargs, depth=depth)
    except Exception as e:
        logger.debug("Caught search exception %s", type(e))
        if depth < max_tries:
            sleep(backoff)
            return try_search(
                *args,
                **kwargs,
                depth=depth + 1,
                backoff=backoff + 0.3,
                max_tries=max_tries,
            )
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
            try_search,
            [
                (keyword, engines[n], 1, kwlang)
                for n in range(min(len(engines), cfg.POOL_SIZE))
            ],
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
    ensure_engines()
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
    logger.info(f"fetching images for {kw}")
    try:
        for egn in get_engine_img():
            response = try_search(
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
