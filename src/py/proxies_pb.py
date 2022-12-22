import asyncio as aio
import copy
import os
import socket
import ssl
import time
import warnings
from collections import deque
from functools import partial
from json.decoder import JSONDecodeError
from multiprocessing import Queue
from pathlib import Path
from threading import Lock
from typing import List, Union

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    import proxybroker as pb
    from proxybroker.api import Broker

import httpx
import pycurl
import requests
from retry import retry
from trafilatura import downloads as tradl
from trafilatura import settings as traset
from user_agent import generate_user_agent

import log
import scheduler as sched

PROXIES_ENABLED = True
STATIC_PROXY = True
STATIC_PROXY_EP = "http://localhost:8877"
PROXY_EP_S5 = "socks5://localhost:8878"
PROXY_EP_S4 = "socks4://localhost:8879"
PROXY_EP_HTTP = "http://localhost:8880"
PROXY_DICT = {"http": STATIC_PROXY_EP, "https": STATIC_PROXY_EP}
REQ_TIMEOUT = 20
CURRENT_PROXY = ""

if "CURL_CLASS" not in globals():
    CURL_CLASS = copy.deepcopy(pycurl.Curl)


def get_proxied_Curl(p=STATIC_PROXY_EP, to=10):
    def proxied():
        c = CURL_CLASS()
        ua = generate_user_agent()
        c.setopt(pycurl.PROXY, p)
        c.setopt(pycurl.SSL_VERIFYHOST, 0)
        c.setopt(pycurl.SSL_VERIFYPEER, 0)
        # self.setopt(pycurl.PROXYTYPE, pycurl.PROXYTYPE_SOCKS5_HOSTNAME)
        c.setopt(pycurl.USERAGENT, ua)
        traset.DEFAULT_CONFIG.set("DEFAULT", "USER_AGENTS", ua)
        traset.TIMEOUT = to
        tradl.TIMEOUT = to
        return c

    return proxied


if "REQUESTS_GET" not in globals():
    REQUESTS_GET = copy.deepcopy(requests.get)
    REQUESTS_POST = copy.deepcopy(requests.post)
    # Handle target environment that doesn't support HTTPS verification
    SSL_DEFAULT_HTTPS_CTX = copy.deepcopy(ssl._create_default_https_context)


def set_requests(proxy=None, to=10):
    def get(*args, **kwargs):
        kwargs["timeout"] = to
        if proxy is not None:
            kwargs["proxies"] = {"https": proxy, "http": proxy}
            kwargs["verify"] = False
        elif "proxies" in kwargs:
            del kwargs["proxies"]
        return REQUESTS_GET(*args, **kwargs)

    requests.get = get

    def post(*args, **kwargs):
        kwargs["timeout"] = to
        if proxy is not None:
            kwargs["proxies"] = {"https": proxy, "http": proxy}
            kwargs["verify"] = False
        elif "proxies" in kwargs:
            del kwargs["proxies"]
        return REQUESTS_POST(*args, **kwargs)

    requests.post = post


def reset_requests():
    requests.get = REQUESTS_GET
    requests.post = REQUESTS_POST


if "DEFAULT_SSL_MODE" not in globals():
    DEFAULT_SSL_MODE = copy.deepcopy(ssl.SSLContext.verify_mode)

if "DEFAULT_HTTPX_SSL" not in globals():
    DEFAULT_HTTPX_SSL = copy.deepcopy(httpx.create_ssl_context)


def set_ssl_mode():
    ssl.SSLContext.verify_mode = property(
        lambda self: ssl.CERT_NONE, lambda self, newval: None
    )
    ssl._create_default_https_context = ssl._create_unverified_context


def reset_ssl_mode():
    ssl.SSLContext.verify_mode = DEFAULT_SSL_MODE
    ssl._create_default_https_context = SSL_DEFAULT_HTTPS_CTX


PROXY_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")


def setproxies(p: str | None = STATIC_PROXY_EP, to=10):
    if p:
        for name in PROXY_VARS:
            os.environ[name] = p
        pycurl.Curl = get_proxied_Curl(p, to=to)
    else:
        prev_proxy = os.getenv(PROXY_VARS[0])
        for name in PROXY_VARS:
            if name in os.environ:
                del os.environ[name]
        pycurl.Curl = CURL_CLASS
        return prev_proxy


def is_unproxied():
    return all(name not in os.environ for name in PROXY_VARS)


def set_socket_timeout(timeout):
    socket.setdefaulttimeout(timeout)


def select_proxy(proxy):
    if proxy is None or proxy <= 0:
        sel = None
    elif proxy == 1:
        sel = get_proxy(static=True)
    elif proxy > 1:
        sel = get_proxy(static=(proxy % 2))
    return sel


def get_current_proxy():
    """NOT async-safe. Only for debugging."""
    return CURRENT_PROXY


class _http_opts(object):
    prev_timeout = 0
    prev_proxy = ""
    timeout = 4
    proxy = None

    def __init__(self):
        return

    def __call__(self, timeout=3, proxy=None):
        global CURRENT_PROXY
        CURRENT_PROXY = self.proxy = select_proxy(proxy)
        self.timeout = timeout
        return self

    def __enter__(self):
        global CURRENT_PROXY
        CURRENT_PROXY = self.proxy
        if self.proxy:
            set_ssl_mode()
        set_requests(proxy=self.proxy, to=self.timeout)
        self.prev_proxy = setproxies(self.proxy, self.timeout)
        self.prev_timeout = socket.getdefaulttimeout()
        socket.setdefaulttimeout(self.timeout)

    def __exit__(self, *_):
        global CURRENT_PROXY
        CURRENT_PROXY = None
        reset_requests()
        reset_ssl_mode()
        setproxies(self.prev_proxy)
        socket.setdefaulttimeout(self.prev_timeout)


http_opts = _http_opts()

LIMIT = 50
TYPES = [
    "HTTP",
    "SOCKS5",
    "SOCKS4",
    "CONNECT:25",
    "CONNECT:80",
]

MAX_PROXIES = 200
PROXIES_URLS = []
PROXIES_URLS_HTTP = []
PROXIES_HTTP = []
PROXIES_HTTPS = []
PROXIES_S4 = []
PROXIES_S5 = []
PROXIES_IDX = [0, 0]  # raw, http
PROXIES_URLS.append(STATIC_PROXY_EP)
PROXIES_HTTP.append(STATIC_PROXY_EP)
LOCK = Lock()
PROXY_MAP = {
    "http": PROXIES_HTTP,
    "https": PROXIES_HTTPS,
    "socks4": PROXIES_S4,
    "socks5": PROXIES_S5,
}
PB: Union[Broker, None] = None


# NOTE: Iterators don't work with proxy classes :(
def next_proxy(http=False):
    with LOCK:
        if http:
            tp = 1  # http
            li = PROXIES_URLS_HTTP
        else:
            tp = 0  # raw
            li = PROXIES_URLS
        idx = PROXIES_IDX[tp]
        size = len(li)
        if size > 0:
            if idx >= size:
                idx = 0
            PROXIES_IDX[tp] = idx + 1
            return li[idx]
        else:
            return STATIC_PROXY_EP

import json

scheme_map = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "HTTPS": "http",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5",
}
proto_map = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "HTTPS": "https",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5",
}
from enum import Enum


class ProxyType(Enum):
    http = "http"
    socks4 = "socks4"
    socks5 = "socks5"


def read_proxies(f):
    with open(f, "r") as f:
        proxies = f.read()
    try:
        proxies = json.loads(proxies)
    except JSONDecodeError:
        if proxies.endswith(",\n"):
            proxies = proxies.rstrip(",\n")
            proxies += "]"  # proxybroker keeps the json file unclosed open
            proxies = json.loads(proxies)
        else:
            proxies = []
    return proxies


@retry(tries=3, delay=1, backoff=3.0)
def sync_from_files(files: List[Path]):
    try:
        global MAX_PROXIES
        urls = []
        urls_http = []
        prev = {proto: ls[:] for (proto, ls) in PROXY_MAP.items()}
        new = {proto: list() for proto in PROXY_MAP.keys()}
        for f in files:
            proxies = read_proxies(f)
            if proxies is None:
                continue
            # Use reverse order since the tail are the most recent ones, and cycling starts from idx 0
            for p in proxies[::-1]:
                host = p["host"]
                port = p["port"]
                types = p["types"]
                for t in types:
                    tp = t["type"]
                    proto = proto_map[tp]
                    ip = f"{host}:{port}"
                    new[proto].append(ip)
                    if tp != "HTTP":
                        schm = scheme_map[tp]
                        urls.append(f"{schm}://{host}:{port}")
                    else:
                        urls_http.append(f"http://{host}:{port}")
        proxies_avg = 0
        del PROXIES_URLS[:]
        PROXIES_URLS.extend(urls)
        del PROXIES_URLS_HTTP[:]
        PROXIES_URLS_HTTP.extend(urls_http)
        for (proto, ls) in PROXY_MAP.items():
            del ls[:]  # manager list proxy does not have `clear` method
            proto_proxies = new[proto]  # the latest list
            proxies_avg += len(proto_proxies)  # how many new to? to update the tail
            proto_proxies.extend(prev[proto])  # append the previous ones
            proto_proxies = list(set(proto_proxies))  # deduplicate
            ls.extend(proto_proxies[:MAX_PROXIES])  # trim according to MAX_PROXIES
        MAX_PROXIES = (
            min(50, proxies_avg // len(PROXY_MAP)) * 2
        )  # update the tail number
    except:
        import traceback

        traceback.print_exc()
        log.logger.warn("Could't sync proxies, was the file being written?")


DEFAULT_PEER_CONFIG = """
strategy round
max_fails 0
fail_timeout 24h
reload 5s
"""


@retry(tries=3, delay=1, backoff=3.0)
def update_gost_config(
    proxies_files: List[Path], config_dir: Path, config_suffix: str = "peers"
):
    """Updates the peers list of the GOST proxy."""
    sync_from_files(proxies_files)
    new_config = {}
    for (proto, proxies) in PROXY_MAP.items():
        if proto == "https":
            proto = "http"
        cfg = new_config.get(proto, [DEFAULT_PEER_CONFIG])
        for p in proxies:
            cfg.append(f"peer {proto}://{p}")
        new_config[proto] = cfg

    for (proto, cfg) in new_config.items():
        path = config_dir / f"{proto}{config_suffix}.txt"
        # print("\n".join(v))
        with open(path, "w") as f:
            f.write("\n".join(cfg))

    # for (proto, p) in PROXY_MAP:
    #     schm = scheme_map[proto]
    # case "HTTP": ProxyType.http
    # print(p)
    # match p[:6]:
    #     case "http:/":
    #         new_config[ProxyType.http].append(f"peer {p}")
    #     case "socks5":
    #         new_config[ProxyType.socks5].append(f"peer {p}")
    #     case "socks4":
    #         new_config[ProxyType.socks4].append(f"peer {p}")
    # for k, v in new_config.items():
    #     path = config_dir / f"{k.value}{config_suffix}.txt"
    #     # print("\n".join(v))
    #     with open(path, "w") as f:
    #         f.write("\n".join(v))


PROXY_SYNC_JOB = None


def proxy_sync_forever(proxies_files: List[Path], config_dir: Path, interval=15):
    global PROXY_SYNC_JOB
    if PROXY_SYNC_JOB is None or PROXY_SYNC_JOB.ready():

        def job():
            while True:
                try:
                    update_gost_config(proxies_files, config_dir)
                    time.sleep(interval)
                except:
                    pass

        sched.initPool()
        PROXY_SYNC_JOB = sched.apply(job)


def get_proxy(static=True, http=False) -> str:
    try:
        return (
            STATIC_PROXY_EP
            if static
            else next_proxy()
            if not http or len(PROXIES_HTTP) <= 1
            else next_proxy(http=True)
        )
    except:
        return STATIC_PROXY_EP


async def fetch_proxies(limit: int, proxies, out: Queue):
    try:
        c = 0
        while c < limit:
            prx = await proxies.get()
            if prx is not None:
                addr = prx.as_text().strip()
                out.put(addr)
                c += 1
        return out
    except IndexError:
        pass


def init_broker(loop, proxies):
    global PB
    try:
        PB = pb.Broker(proxies)
    except Exception as e:
        log.logger.warning("Cannot initialize ProxyBroker %s", e)


def get_loop():
    try:
        return aio.get_running_loop()
    except:
        return aio.new_event_loop()


def find_proxies(out: Queue, limit=LIMIT, loop=None):
    try:
        if loop is None:
            loop = get_loop()
        proxies = aio.Queue()
        init_broker(loop, proxies)
        assert PB is not None
        tasks = aio.gather(
            PB.find(types=TYPES, limit=limit), fetch_proxies(limit, proxies, out)
        )
        loop.run_until_complete(tasks)
        return out
    except Exception as e:
        print(e)
        log.logger.info("find_proxies: ", e)


def flush_queue(out: Queue):
    for _ in range(out.qsize()):
        p = out.get()
        PROXIES_URLS.appendleft(p)


def find_proxies_proc(limit: int = LIMIT):
    out = Queue(maxsize=limit)
    p = Process(
        target=find_proxies,
        args=(
            out,
            limit,
        ),
    )
    p.run()
    return (out, p)


# if __name__ == "__main__":
#     limit = 10
#     out = Queue(maxsize=limit)
#     find_proxies(out, limit)
#     while out.qsize() > 0:
#         print(out.get_nowait())
