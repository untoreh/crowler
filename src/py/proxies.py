import urllib.request, socket
import random
from urllib.parse import urlparse
from pathlib import Path
import config as cfg
import utils as ut
import json
import log

JUDGES = [
    "http://mojeip.net.pl/asdfa/azenv.php",
    "http://www.proxy-listen.de/azenv.php",
    "http://proxyjudge.us",
]
JUDGES_OK = None
PROXIES = dict()


def validate_judges():
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
    if JUDGES_OK is None:
        validate_judges()
    try:
        pr = urlparse(proxy)
        proxy_handler = urllib.request.ProxyHandler({pr.scheme: proxy})
        opener = urllib.request.build_opener(proxy_handler)
        opener.addheaders = [("User-agent", "Mozilla/5.0")]
        urllib.request.install_opener(opener)
        urllib.request.urlopen(random.choice(JUDGES))  # change the url address here
    except urllib.error.HTTPError as e:
        if verbose:
            log.logger.debug(e.code)
        return False
    except Exception as detail:
        if verbose:
            log.logger.debug(detail)
        return True
    return True


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
            addproxies(PROXIES, "socks5", data)

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
                    addproxies(PROXIES, tp, ls)

    def speedx(self):
        data = ut.fetch_data(
            "https://github.com/TheSpeedX/PROXY-List/raw/master/http.txt"
        )
        # if one is stale all of them probably are
        if data == self.speedx_last:
            log.logger.critical("Stale speedx list!")
            return
        elif data:
            addproxies(PROXIES, "http", data.split())
        for tp in ("socks4", "socks5"):
            data = ut.fetch_data(
                f"https://github.com/TheSpeedX/PROXY-List/raw/master/{tp}.txt"
            )
            if data:
                addproxies(PROXIES, tp, data.split())

    def fetch(self):
        cfg.setproxies(None)
        self.hookzof()
        self.jetkai()
        for k, l in PROXIES.items():
            PROXIES[k] = ut.dedup(l)
        return PROXIES

    def dump(self, root="", prefix=None):
        if not prefix:
            prefix = self.dump_prefix
        for prot in PROXIES.keys():
            path = Path(root) / f"{prefix}_{prot}.txt"
            with open(path, "w") as f:
                concat = lambda addr: f"{prot}://{addr}"
                proxies = list(map(concat, PROXIES[prot]))
                f.write("\n".join(proxies))

    def getproxy(self, tp="http"):
        l = PROXIES.get(tp)
        if l:
            return random.choice(l)
