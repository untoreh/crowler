import asyncio as aio
from json.decoder import JSONDecodeError
import proxybroker as pb
from proxybroker.api import Broker
from collections import deque
from typing import Union
import scheduler as sched
from multiprocessing import Process, Queue
from retry import retry
import time

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

PROXIES_SET = set()
N_PROXIES = 200
PROXIES = deque(maxlen=N_PROXIES)
PROXIES.extendleft([cfg.STATIC_PROXY_EP])
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
            yield cfg.STATIC_PROXY_EP

PROXY_ITER = iter(next_proxy())

import config as cfg
import json

typemap = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5"
}

@retry(tries=3, delay=1, backoff=3.0)
def sync_from_file(wait_time=10):
    try:
        with open(cfg.PROXIES_DIR / "pbproxies.json", "r") as f:
            proxies = f.read()
        try:
            proxies = json.loads(proxies)
        except JSONDecodeError:
            assert proxies.endswith(",\n")
            proxies = proxies.rstrip(",\n")
            proxies += "]" # proxybroker keeps the json file unclosed open
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

def proxy_sync_forever(interval=60):
    while True:
        sync_from_file()
        time.sleep(interval)

def get_proxy(static=True) -> str:
    try:
        return cfg.STATIC_PROXY_EP if static else next(PROXY_ITER)
    except Exception:
        return cfg.STATIC_PROXY_EP

sched.initPool()
sched.apply(proxy_sync_forever)

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
