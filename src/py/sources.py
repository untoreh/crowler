import os
import sys
from random import shuffle
from time import sleep, time
from typing import Dict, List
import pickle

import searx
from searx import search
from searx.search import EngineRef, SearchQuery

import config as cfg
import proxies_pb as pb
import scheduler as sched
import translator as tr
import traceback as tb
from log import LoggerLevel, logger, logging

# the searx.search module has a variable/ named `processors`
# import importlib

# proc = importlib.import_module("searx.search.processors", package="searx")

# Path params to disable ssl verification
# online_req_params = proc.online.default_request_params()

# def default_request_params():
#     online_req_params["verify"] = False
#     return online_req_params

# proc.online.default_request_params = default_request_params

SEARX_ENABLED_CATEGORIES = [
    "general",
    "images",
    "videos",
    "apps",
    "software wikis",
    "science",
    "music",
    "web",
    "news",
    "other",
    "others",
    "map",
    "dictionaries",
    "q&a",
]
# DEFAULT_ENGINES = ["google", "startpage", "reddit", "duckduckgo", "bing"]
# DEFAULT_ENGINES_IMG = [
#     "google_images",  # lang is not initialized problem
#     "duckduckgo_images",
#     "bing_images",
#     "flickr_noapi",
#     "frinkiac",
# ]

ENGINES_PROXIES = {}


def def_engine_proxies():
    global ENGINES_PROXIES
    engines = searx.settings["engines"]
    for egn in engines:
        ENGINES_PROXIES[egn["name"]] = {
            "http": pb.STATIC_PROXY_EP,
            "https": pb.STATIC_PROXY_EP,
        }


def set_egn_proxy(name: str):
    ENGINES_PROXIES[name]["http"] = pb.get_proxy(static=False, http=True)
    ENGINES_PROXIES[name]["https"] = pb.get_proxy(static=False, http=False)


def switch_searx_proxies(engine):
    if isinstance(engine, (str, EngineRef)):
        name = engine.name if isinstance(engine, EngineRef) else engine
        set_egn_proxy(name)
    else:
        assert (
            isinstance(engine, List)
            and len(engine)
            and isinstance(engine[0], EngineRef)
        )
        for e in engine:
            set_egn_proxy(e.name)


def print_engine_proxy(engine):
    for egn in searx.settings["engines"]:
        if egn["name"] == engine:
            print(egn["network"]["proxies"])


def get_searx_settings():
    settings = searx.settings
    for egn in settings["engines"]:
        egn["timeout"] = cfg.REQ_TIMEOUT
        egn["network"] = {
            "verify": False,
            "proxies": ENGINES_PROXIES[egn["name"]],
            "retries": 0,
            "retry_on_http_error": False,
            "max_redirects": 30,
        }
    settings["outgoing"].update(
        {
            "request_timeout": cfg.REQ_TIMEOUT,
            "max_request_timeout": cfg.REQ_TIMEOUT + 1,
            "pool_connections": 100,
            "pool_maxsize": 3,
            "verify": False,
            # "enable_http": True,
            # "retries": 1,
        }
    )
    return settings["engines"]


PROCESSORS = None
ENGINES_TRACKING: Dict[str, Dict[EngineRef, int]] = {}  # {cat, {egn_ref, n_fails}}
SCHEDULED_SEARCHES = {}
LAST_ENGINES_SNAPSHOT = 0
ENGINES_SNAPSHOT_INTERVAL = 60


def save_tracking(force=False):
    try:
        global LAST_ENGINES_SNAPSHOT
        if time() - LAST_ENGINES_SNAPSHOT > ENGINES_SNAPSHOT_INTERVAL or force:
            with open(cfg.CONFIG_DIR / "engines.pkl", "wb") as f:
                pickle.dump(ENGINES_TRACKING, f)
            LAST_ENGINES_SNAPSHOT = time()
    except:
        logger.warn("failed to save engine stats.")


def load_tracking():
    try:
        with open(cfg.CONFIG_DIR / "engines.pkl", "rb") as f:
            ENGINES_TRACKING.update(pickle.load(f))
    except:
        logger.warn("failed to load engine stats.")


def hotfixes():
    # fix for non initialized langs
    eng = searx.engines.engines.get("google-images")
    if not eng is None and not eng.supported_languages:
        if not eng.supported_languages:
            eng.supported_languages = eng.fetch_supported_languages()


def ensure_engines(force=False):
    global PROCESSORS, SCHEDULED_SEARCHES
    if force or PROCESSORS is None:
        print("Ensuring searx engines are loaded...")
        searx.network.network.NETWORKS.clear()
        searx.search.PROCESSORS.clear()
        searx.engines.engines.clear()
        def_engine_proxies()
        search.initialize(settings_engines=get_searx_settings())
        hotfixes()

        if not len(ENGINES_TRACKING):
            for cat in SEARX_ENABLED_CATEGORIES:
                engines_for_cat = searx.engines.categories[cat]
                ENGINES_TRACKING[cat] = {
                    EngineRef(engine.name, cat): 0 for engine in engines_for_cat
                }
            load_tracking()
    assert searx.search.PROCESSORS
    if PROCESSORS is None:
        PROCESSORS = searx.search.PROCESSORS


def all_searx_categories():
    list(searx.engines.categories.keys())


def unsuspend_processors():
    for eng in PROCESSORS.values():
        eng.suspended_status.resume()


def cancel_search(kw: str):
    del SCHEDULED_SEARCHES[kw]


def single_search(
    kw,
    engine=None,
    pages=1,
    lang="all",
    timeout=cfg.REQ_TIMEOUT,
    category="general",
    force=False,
):
    res = []
    logger.info(f"Processing engine search, kw: {kw}")
    assert isinstance(ENGINES_TRACKING, Dict)
    engines = (
        list(ENGINES_TRACKING[category].keys())
        if engine is None
        else [engine]
        if isinstance(engine, EngineRef)
        else [EngineRef(engine, category)]
    )
    time_ranges = ["", "year"]
    current_tr = "month"
    while True:
        if not force and kw not in SCHEDULED_SEARCHES:
            return []
        try:
            unsuspend_processors()
            s = SearchQuery(
                kw,
                engines,
                safesearch=1,
                time_range=current_tr,
                timeout_limit=timeout,
                # pageno=p,
                lang=lang,
            )
            switch_searx_proxies(engine)
            q = search.Search(s).search()
            q_res = q.get_ordered_results()
            if len(q_res) > 0:
                res.extend(q_res)
                break
            elif not len(time_ranges):
                break
            else:
                current_tr = time_ranges.pop()
        except:
            for e in engines:
                cat = ENGINES_TRACKING.get(category, {})
                fails = cat.get(e, 0)
                cat[e] = fails + 1
                ENGINES_TRACKING[category] = cat
    return res


def try_search(kw, *args, **kwargs):
    try:
        return single_search(kw, *args, **kwargs)
    except:
        logger.warn("Caught search exception %s", tb.format_exc())
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
    category="general",
    verbose=False,
    filter_lang=False,
    sync=True,
    top_egn=5,
):
    """
    Search a keyword across all supported engines for given  category.

    `top_egn`: only search across the top n best performing engines.
    """
    try:
        SCHEDULED_SEARCHES[keyword] = True
        logger.info("Finding sources for keyword: %s", keyword)
        ensure_engines()
        ranks = sorted(ENGINES_TRACKING[category].items(), key=lambda x: x[1])
        engines = [e[0] for e in ranks[:top_egn]]
        assert isinstance(engines[0], EngineRef)

        kwlang = tr.detect(keyword) if filter_lang else "all"
        jobs = []
        for e in engines:
            jobs.append(sched.apply(try_search, keyword, e, 1, kwlang))
        res = []
        if sync:
            for j in jobs:
                res.extend(j.get())
        else:
            return jobs
    except KeyboardInterrupt:
        assert sched.PROC_POOL is not None
        print("Caught KB interrupt.")
        sched.PROC_POOL.close()
        print("Terminating pool...")
        sched.PROC_POOL.terminate()
        # shut up requests in flight warning
        sys.stdout = os.devnull
        sys.stderr = os.devnull
        with LoggerLevel(quiet=True):
            exit()
    res = dedup_results(res)
    if verbose:
        print(res)
    if keyword in SCHEDULED_SEARCHES:
        del SCHEDULED_SEARCHES[keyword]
    save_tracking()
    return res


from typing import Dict, NamedTuple


class Img(NamedTuple):
    title: str
    url: str
    origin: str


def get_images(kw, maxiter=3, min_count=1, raw=False):
    """"""
    results = []
    logger.info(f"fetching images for {kw}")
    try:
        # engines = ENGINES["images"]
        # for e in
        for n in range(1, maxiter + 1):
            response = try_search(
                kw,
                None,
                pages=n,
                lang="all",
                timeout=cfg.REQ_TIMEOUT,
                category="images",
            )
            results.extend(response)
            if len(results) > min_count:
                break
    finally:
        save_tracking()
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
