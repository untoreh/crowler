from requests.exceptions import ConnectTimeout, ProxyError, SSLError
from requests import get
from multiprocessing.pool import ThreadPool
import json
from search_engines.engine import SearchEngine
# import SearchEngine
import search_engines as se
from random import choice
import config

# from proxycheck import set_socket_timeout
# set_socket_timeout(10)

from searx.search import SearchQuery, EngineRef
from searx import search, engines


RESULTS = dict()
ENGINES = set(se.__all__)
# remove proxy unfriendly engines
ENGINES.remove("Torch")
ENGINES.remove("Dogpile")
ENGINES.remove("Mojeek")
ENGINES.remove("Bing")
ENGINES.remove("Google")

import warnings

warnings.simplefilter("ignore")


def get_engines(proxy, timeout=10):
    egs = []
    for eg in ENGINES:
        cls = getattr(se, eg)
        egs.append(cls(proxy=proxy, timeout=timeout))
    return egs


def all_search(*args):
    try:
        proxy = choice(tuple(PROXIES))
        for eg in get_engines(proxy=proxy):
            fetched = eg.search("VPS Trial", pages=2)
            results[eg] = fetched.links()
    except (ConnectTimeout, ProxyError, SSLError):
        # switch_proxy(client)
        all_search()

def single_search(engine, query, pages=1, timeout=15, depth=0):
    depth += 1
    try:
        eg: SearchEngine = getattr(se, engine)(timeout=timeout)
        # Disable SSL Cert verification
        eg._http_client.session.verify = False
        fetched = eg.search(query, pages=pages)
        if len(fetched.results()) == 0 and depth < config.SRC_MAX_TRIES:
            single_search(engine, timeout=timeout, depth=depth)
        else:
            RESULTS[engine] = fetched.links()
    except:
        if not config.STATIC_PROXY:
            PROXIES[proxy][engine] = False
        if depth < config.SRC_MAX_TRIES:
            single_search(engine, query, pages=pages, timeout=timeout, depth=depth)


def dedup_results():
    all_results = []
    for r in RESULTS.values():
        all_results.extend(r)
    return list(dict.fromkeys(all_results).keys())


# try:
#     single_search("Qwant", 2, timeout=20, use_proxy=True)
# except KeyboardInterrupt:
#     exit()


def execute(keyword="trending", verbose=False):
    pool = ThreadPool(processes=len(ENGINES))
    try:
        pool.starmap(single_search, [(eg, keyword, 2) for eg in ENGINES])
    except KeyboardInterrupt:
        pass
    with open(config.SRC_FILE, "w") as f:
        json.dump(dedup_results(), f)
    if verbose:
        print(RESULTS)

def ssearch
eg = [{"engine": x, "name": x, "shortcut": x} for x in ("google", "bing", "qwant", "reddit", "twitter")]
engines.load_engines(eg)
search.initialize()
s = SearchQuery('cars', [EngineRef("bing", "")], timeout_limit=10)
res = search.Search(s).search()
