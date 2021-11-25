from requests.exceptions import ConnectTimeout, ProxyError, SSLError
from requests import get
from multiprocessing.pool import ThreadPool
import json
from search_engines.engine import SearchEngine
import search_engines as se
from random import choice
from proxycheck import (check_proxy, set_socket_timeout)
set_socket_timeout(10)

PROXIES_EP = "http://127.0.0.1:8080/proxies.json"
STATIC_PROXY_EP = "socks5h://127.0.0.1:8082"
STATIC_PROXY = True

PROXIES = dict()
ENGINES = set(se.__all__)
# remove proxy unfriendly engines
ENGINES.remove("Torch")
ENGINES.remove("Dogpile")
ENGINES.remove("Mojeek")
ENGINES.remove("Bing")
ENGINES.remove("Google")

MAX_TRIES = 5
# {'Startpage', 'Ask', 'Mojeek', 'Yahoo', 'Duckduckgo', 'Aol', 'Bing', 'Google', 'Qwant'}
import warnings
warnings.simplefilter("ignore")
# import logging
# logger = logging.getLogger()
# # only log really bad events
# logger.setLevel(10)

def get_engines(proxy, timeout=10):
    egs = []
    for eg in ENGINES:
        cls = getattr(se, eg)
        egs.append(cls(proxy=proxy, timeout=timeout))
    return egs

def get_proxies():
    proxies = get(PROXIES_EP).content.splitlines();
    for p in proxies:
        parts = p.split()
        url = str(parts[-1]).rstrip(">'").lstrip("b'")
        prot_type = str(parts[3]).rstrip(":'").lstrip("'b'[").rstrip("]").rstrip(",")
        if prot_type == "HTTP" or prot_type == "CONNECT:80" or prot_type == "CONNECT:25":
            prot = "http://"
        elif prot_type == "HTTPS":
            prot = "https://"
        elif prot_type == "SOCKS5":
            prot = "socks5h://"

        prx = f"{prot}{url}"
        PROXIES[prx] = {eg: True for eg in ENGINES}

get_proxies()

results = dict()
prx_iter = iter(set(PROXIES))
# client = yag.SearchClient("VPS trial", verify_ssl=False)

def switch_proxy(client):
    prx = next(prx_iter).lower()
    client.assign_random_user_agent()
    assert prx != client.proxy
    client.proxy = prx
    client.proxy_dict["http"] = prx
    client.proxy_dict["https"] = prx
    print(client.proxy)

# switch_proxy(*args)

def all_search(*args):
    try:
        proxy = choice(PROXIES)
        for eg in get_engines(proxy=proxy):
            fetched = eg.search("VPS Trial", pages=2)
            results[eg] = fetched.links()
    except (ConnectTimeout, ProxyError, SSLError):
        # switch_proxy(client)
        all_search()

def engine_proxy(engine):
    while True:
        proxy = choice(tuple(PROXIES.keys()))
        if PROXIES[proxy][engine]:
            break
    return proxy

def get_proxy(engine, static=True, check=True):
    if static:
        return "http://127.0.0.1:8082"
    else:
        proxy = engine_proxy(engine)
    if not check:
        return proxy
    while not check_proxy(proxy, 5):
        del PROXIES[proxy]
        if len(PROXIES) == 0:
            raise RuntimeError("Not more Proxies Available")
        proxy = choice(tuple(PROXIES))
    return proxy


def single_search(engine, query, pages=1, timeout=15, depth=0, use_proxy=True):
    if use_proxy:
        proxy = get_proxy(engine, static=STATIC_PROXY, check=False)
    else: proxy = None
    depth += 1
    try:
        eg: SearchEngine = getattr(se, engine)(proxy=proxy, timeout=timeout)
        # Disable SSL Cert verification
        eg._http_client.session.verify = False
        fetched = eg.search(query, pages=pages)
        if len(fetched.results()) == 0 and depth < MAX_TRIES:
            single_search(engine, timeout=timeout, depth=depth)
        else:
            results[engine] = fetched.links()
    except:
        if not STATIC_PROXY:
            PROXIES[proxy][engine] = False
        if depth < MAX_TRIES:
            single_search(engine, query, pages=pages, timeout=timeout, depth=depth)


def dedup_results():
    all_results = []
    for r in results.values():
        all_results.extend(r)
    return list(dict.fromkeys(all_results).keys())

# try:
#     single_search("Qwant", 2, timeout=20, use_proxy=True)
# except KeyboardInterrupt:
#     exit()

pool = ThreadPool(processes=len(ENGINES))
try:
    pool.starmap(single_search, [(eg, "VPS Trial", 2) for eg in ENGINES])
except KeyboardInterrupt:
    pass

with open("results.json", "w") as f:
    json.dump(dedup_results(), f)

print(results)
