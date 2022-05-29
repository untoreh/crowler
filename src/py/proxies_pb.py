import asyncio as aio
import proxybroker as pb
from proxybroker.api import Broker
from collections import deque
from typing import Union
import scheduler as sched
from multiprocessing import Process, Queue

# warnings.simplefilter("ignore")

import config as cfg
import log

LIMIT = 50
TYPES = [
    "HTTP",
    "SOCKS5",
    "SOCKS4",
    "CONNECT:25",
    "CONNECT:80",
]

PROXIES = deque(maxlen=200)
PB: Union[Broker, None] = None


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


import config as cfg
import random
from itertools import cycle
import json

typemap = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5"
}
PROXIES_CYCLE = cycle(PROXIES)
PROXIES_CYCLE_F = lambda: next(PROXIES_CYCLE)
# 2 times free proxies, 1 time private proxies
PROXY_CHOICE = (lambda: cfg.STATIC_PROXY_EP, PROXIES_CYCLE_F, PROXIES_CYCLE_F)

def sync_from_file():
    try:
        with open(cfg.PROXIES_DIR / "pbproxies.json", "r") as f:
            proxies = json.load(f)
        for p in proxies:
            host = p["host"]
            port = p["port"]
            types = p["types"]
            for t in types:
                tp = t["type"]
                tpm = typemap[tp]
                PROXIES.appendleft(f"{tpm}://{host}:{port}")
            # set cycle again since proxies mutated
            global PROXIES_CYCLE
            PROXIES_CYCLE = cycle(PROXIES)
    except:
        log.logger.debug("Could't sync proxies, was the file being written?")

def get_proxy():
    i = random.randrange(3)
    return PROXY_CHOICE[i]()


# if __name__ == "__main__":
#     limit = 10
#     out = Queue(maxsize=limit)
#     find_proxies(out, limit)
#     while out.qsize() > 0:
#         print(out.get_nowait())