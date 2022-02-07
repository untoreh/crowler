import config as cfg

from retry import retry
from requests import get
from multiprocessing.pool import ThreadPool
import json
from random import choice

# from proxycheck import set_socket_timeout
# set_socket_timeout(10)

from searx.search import SearchQuery, EngineRef
from searx import search, engines, settings, network

for k in ("all", "http", "https"):
    settings["proxies"][k] = cfg.STATIC_PROXY_EP

network.initialize(settings_outgoing={"proxies" : {"https": cfg.STATIC_PROXY_EP, "http": cfg.STATIC_PROXY_EP}})

RESULTS = dict()
ENGINES = ["google", "bing", "qwant", "reddit", "onesearch", "digg", "duckduckgo", "startpage", "brave"]
ENGINES_PARAMS = [{"engine": e, "name": e, "shortcut": e} for e in ENGINES]
search.initialize()


@retry(tries=cfg.SRC_MAX_TRIES)
def single_search(kw, engine, pages=1, timeout=cfg.REQ_TIMEOUT):
    RESULTS[engine] = []
    for p in range(pages):
        s = SearchQuery(kw, [EngineRef(engine, "")], timeout_limit=timeout)
        q = search.Search(s).search()
        res = q.get_ordered_results()
        if len(res) == 0:
            if p == 1:
                raise ValueError
        else:
            RESULTS[engine].extend(res)

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

def execute(keyword="trending", verbose=False, n_engines=1, n_workers=cfg.WORKERS):
    """
    `n_engines`: How many search engines to query.
    `n_workers`: How many queries to run in parallel.
    """
    pool = ThreadPool(processes=n_workers)
    try:
        pool.starmap(single_search, [(keyword, choice(ENGINES), 2) for _ in range(n_workers)])
    except KeyboardInterrupt:
        pass
    with open(cfg.SRC_FILE, "w") as f:
        json.dump(dedup_results(), f)
    if verbose:
        print(RESULTS)
