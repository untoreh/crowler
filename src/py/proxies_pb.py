import asyncio as aio
from pathlib import Path
import copy
import os
import socket
import time
from collections import deque
from json.decoder import JSONDecodeError
from multiprocessing import Process, Queue
from typing import Union

import proxybroker as pb
import pycurl
from proxybroker.api import Broker
from retry import retry
from trafilatura import downloads as tradl
from trafilatura import settings as traset
from user_agent import generate_user_agent

import log
import scheduler as sched

PROXIES_ENABLED = True
STATIC_PROXY_EP = "socks5://localhost:8877"
STATIC_PROXY = True
PROXY_DICT = {"http": STATIC_PROXY_EP, "https": STATIC_PROXY_EP}
REQ_TIMEOUT = 20

if "CURL_CLASS" not in globals():
    CURL_CLASS = copy.deepcopy(pycurl.Curl)


def get_curlproxy(p=STATIC_PROXY_EP):
    def curlproxy():
        c = CURL_CLASS()
        ua = generate_user_agent()
        c.setopt(pycurl.PROXY, p)
        c.setopt(pycurl.SSL_VERIFYHOST, 0)
        c.setopt(pycurl.SSL_VERIFYPEER, 0)
        # self.setopt(pycurl.PROXYTYPE, pycurl.PROXYTYPE_SOCKS5_HOSTNAME)
        c.setopt(pycurl.USERAGENT, ua)
        traset.DEFAULT_CONFIG.set("DEFAULT", "USER_AGENTS", ua)
        traset.TIMEOUT = REQ_TIMEOUT
        tradl.TIMEOUT = REQ_TIMEOUT
        return c

    return curlproxy


PROXY_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")


def setproxies(p=STATIC_PROXY_EP):
    if p:
        for name in PROXY_VARS:
            os.environ[name] = p
        pycurl.Curl = get_curlproxy()
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


class http_opts(object):
    prev_timeout = 0
    prev_proxy = ""
    timeout = 10
    proxy = None

    def __init__(self, timeout=10, proxy=None):
        if proxy == "auto":
            self.proxy = get_proxy()
        else:
            self.proxy = proxy
        self.timeout = timeout
        return self

    def __call__(self):
        return self

    def __enter__(self):
        self.prev_proxy = setproxies(self.proxy)
        self.prev_timeout = socket.getdefaulttimeout()
        socket.setdefaulttimeout(self.timeout)

    def __exit__(self):
        setproxies(self.prev_proxy)
        socket.setdefaulttimeout(self.prev_timeout)


LIMIT = 50
TYPES = [
    "HTTP",
    "SOCKS5",
    "SOCKS4",
    "CONNECT:25",
    "CONNECT:80",
]

PROXIES_SET = set()
N_PROXIES = 200
PROXIES = deque(maxlen=N_PROXIES)
PROXIES.extendleft([STATIC_PROXY_EP])
PB: Union[Broker, None] = None


def next_proxy():
    i = 0
    while True:
        if len(PROXIES) > 0:
            if i >= len(PROXIES):
                i = 0
            yield PROXIES[i]
            i += 1
        else:
            yield STATIC_PROXY_EP


PROXY_ITER = iter(next_proxy())

import json

typemap = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5",
}


@retry(tries=3, delay=1, backoff=3.0)
def sync_from_file(file_path: Path):
    try:
        with open(file_path, "r") as f:
            proxies = f.read()
        try:
            proxies = json.loads(proxies)
        except JSONDecodeError:
            assert proxies.endswith(",\n")
            proxies = proxies.rstrip(",\n")
            proxies += "]"  # proxybroker keeps the json file unclosed open
            proxies = json.loads(proxies)
        PROXIES_SET = set(PROXIES)
        for p in proxies:
            host = p["host"]
            port = p["port"]
            types = p["types"]
            for t in types:
                tp = t["type"]
                tpm = typemap[tp]
                if tpm:
                    PROXIES_SET.add(f"{tpm}://{host}:{port}")
        PROXIES.clear()
        PROXIES.extendleft(PROXIES_SET)
    except:
        log.logger.debug("Could't sync proxies, was the file being written?")

PROXY_SYNC_RUNNING = False

def proxy_sync_forever(file_path: Path, interval=60):
    global PROXY_SYNC_RUNNING
    if not PROXY_SYNC_RUNNING:
        PROXY_SYNC_RUNNING = True
        while True:
            sync_from_file(file_path)
            time.sleep(interval)


def get_proxy(static=True) -> str:
    try:
        return STATIC_PROXY_EP if static else next(PROXY_ITER)
    except Exception:
        return STATIC_PROXY_EP


sched.initPool()

async def fetch_proxies(limit: int, proxies, out: Queue):
    try:
        c = 0
        while c < limit:
            prx = await proxies.get()
            if prx is not None:
                print(prx)
                addr = prx.as_text().strip()
                out.put(addr)
                c += 1
        return out
    except IndexError:
        pass


def init_broker(loop, proxies):
    global PB
    try:
        sched.initPool()
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
        PROXIES.appendleft(p)


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
