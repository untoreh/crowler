import urllib.request, socket
from typing import Tuple
import random
from pathlib import Path
import json
import log
import resource
import time
from proxy_checker import ProxyChecker
import time
from copy import deepcopy

import config as cfg
import utils as ut
import scheduler

checker = ProxyChecker()


checker = ProxyChecker()
JUDGES = [
    "http://mojeip.net.pl/asdfa/azenv.php",
    "http://www.proxy-listen.de/azenv.php",
    "http://proxyjudge.us",
]
JUDGES_OK = None
PROXIES = dict()
UPDATE_FREQ = 60 * 5

def set_resource_limit():
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (10000, hard))

def validate_judges():
    set_resource_limit()
    for j in JUDGES:
        try:
            code = urllib.request.urlopen(j).getcode()
            if code != 200:
                JUDGES.remove(j)
        except:
            JUDGES.remove(j)
    if len(JUDGES) == 0:
        raise RuntimeError("No judges available for proxy checking")


def set_socket_timeout(timeout):
    socket.setdefaulttimeout(timeout)


set_socket_timeout(5)


def check_proxy(proxy, timeout, verbose=False):
    # if JUDGES_OK is None:
    #     validate_judges()
    if checker.send_query(proxy=proxy):
        return proxy
    # try:
    #     pr = urlparse(proxy)
    #     proxy_handler = urllib.request.ProxyHandler({pr.scheme: proxy})
    #     opener = urllib.request.build_opener(proxy_handler)
    #     opener.addheaders = [("User-agent", "Mozilla/5.0")]
    #     urllib.request.install_opener(opener)
    #     urllib.request.urlopen(JUDGES[0])  # change the url address here
    # except urllib.error.HTTPError as e:
    #     if verbose:
    #         log.logger.debug(e.code)
    #     return False
    # except Exception as detail:
    #     if verbose:
    #         log.logger.debug(detail)
    #     return True
    # return True


def get_proxies():
    proxies = get(cfg.PROXIES_EP).content.splitlines()
    for p in proxies:
        parts = p.split()
        url = str(parts[-1]).rstrip(">'").lstrip("b'")
        prot_type = str(parts[3]).rstrip(":'").lstrip("'b'[").rstrip("]").rstrip(",")
        if (
            prot_type == "HTTP"
            or prot_type == "CONNECT:80"
            or prot_type == "CONNECT:25"
        ):
            prot = "http://"
        elif prot_type == "HTTPS":
            prot = "https://"
        elif prot_type == "SOCKS5":
            prot = "socks5h://"

        prx = f"{prot}{url}"
        PROXIES[prx] = {eg: True for eg in ENGINES}


prx_iter = iter(set(PROXIES))


def switch_proxy(client):
    prx = next(prx_iter).lower()
    client.assign_random_user_agent()
    assert prx != client.proxy
    client.proxy = prx
    client.proxy_dict["http"] = prx
    client.proxy_dict["https"] = prx
    print(client.proxy)


def engine_proxy(engine):
    while True:
        proxy = choice(tuple(PROXIES.keys()))
        if PROXIES[proxy][engine]:
            break
    return proxy


def get_proxy(engine, static=True, check=True):
    if static:
        return cfg.STATIC_PROXY_EP
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


def addproxies(d, k, v):
    if isinstance(d.get(k), list):
        d[k].extend(v)
    else:
        d[k] = v


class Providers:
    hookzof_last = ""
    jetkai_last = ""
    speedx_last = ""
    dump_prefix = "proxies"

    def __init__(self):
        scheduler.initPool()
        self._last_update = 0
        self.proxies = {}
        self.proxy_types = set()
        self.fetch()

    def hookzof(self):
        data = ut.fetch_data(
            "https://raw.githubusercontent.com/hookzof/socks5_list/master/proxy.txt",
            fromcache=False,
        )
        if not data:
            return
        if data == self.hookzof_last:
            log.logger.critical("Stale hookzof proxy list!")
        else:
            data = data.split()
            addproxies(self.proxies, "socks5", data)
            self.proxy_types.add("socks5")

    def jetkai(self):
        data = ut.fetch_data(
            "https://github.com/jetkai/proxy-list/raw/main/online-proxies/json/proxies.json",
            fromcache=False,
        )
        if not data:
            return
        if data == self.jetkai_last:
            log.logger.critical("Stale jetkai proxy list!")
        else:
            data = json.loads(data)
            for tp, ls in data.items():
                # don't use https proxy since they can't be forwarded
                if tp != "https":
                    addproxies(self.proxies, tp, ls)
                    self.proxy_types.add(tp)

    def speedx(self):
        data = ut.fetch_data(
            "https://github.com/TheSpeedX/PROXY-List/raw/master/http.txt"
        )
        # if one is stale all of them probably are
        if data == self.speedx_last:
            log.logger.critical("Stale speedx list!")
            return
        elif data:
            addproxies(self.proxies, "http", data.split())
            self.proxy_types.add("http")
        for tp in ("socks4", "socks5"):
            data = ut.fetch_data(
                f"https://github.com/TheSpeedX/PROXY-List/raw/master/{tp}.txt"
            )
            if data:
                addproxies(self.proxies, tp, data.split())
                self.proxy_types.add(tp)

    def fetch(self):
        if time.time() - self._last_update > UPDATE_FREQ:
            print("Fetching proxies")
            cfg.setproxies(None)
            self.hookzof()
            # self.jetkai()
            # self.speedx()
            for k, l in self.proxies.items():
                self.proxies[k] = ut.dedup(l)
            self._last_update = time.time()
            self.prev_proxies = deepcopy(self.proxies)
        return self.proxies

    def dump(self, root: str | Path = cfg.PROXIES_DIR, prefix=None, data=None):
        if data is None:
            data = self.proxies
        if not prefix:
            prefix = self.dump_prefix
        for prot in data.keys():
            path = Path(root) / f"{prefix}_{prot}.txt"
            with open(path, "w") as f:
                # concat = lambda addr: f"{prot}://{addr}"
                # proxies = list(map(concat, PROXIES[prot]))
                proxies = data[prot]
                f.write("\n".join(proxies))

    def _select_proxy(self):
        types = list(self.proxy_types)
        while len(types) > 0:
            n = random.randrange(len(types))
            pl = self.proxies[types[n]]
            if pl:
                return f"{types[n]}://{pl.pop()}"
            else:
                del types[n]

    def getproxy(self):
        self.fetch()
        p = self._select_proxy()
        if p is None:
            self.proxies = deepcopy(self.prev_proxies)
            return self._select_proxy()
        else:
            return p

    def save(self):
        self.fetch()
        self.dump()

    def checkall(self, verbose=False):
        scheduler.initPool()
        self.fetch()
        global checked
        checked = {}
        jobs = []

        def check_append(tp, p):
            if check_proxy(p, 5, verbose):
                checked[tp].append(p)

        for (tp, plist) in self.proxies.items():
            checked[tp] = []
            for p in plist:
                prx = f"{tp}://{p}"
                j = scheduler.apply(check_append, tp, prx)
                jobs.append(j)
                if len(jobs) == cfg.POOL_SIZE:
                    jobs[0].wait()
                    del jobs[0]
                for (n, j) in enumerate(jobs):
                    if j.ready():
                        j.wait()
                        del jobs[n]
        for j in jobs:
            j.wait()
        self.dump(data=checked)
        return checked
