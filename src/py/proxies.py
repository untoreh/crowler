import urllib.request, socket
import random
from urllib.parse import urlparse
import config

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
        sock = urllib.request.urlopen(
            random.choice(JUDGES)
        )  # change the url address here
        # sock=urllib.urlopen(req)
    except urllib.error.HTTPError as e:
        if verbose:
            print("Error code: ", e.code)
        return False
    except Exception as detail:
        if verbose:
            print("ERROR:", detail)
        return True
    return True


def get_proxies():
    proxies = get(config.PROXIES_EP).content.splitlines()
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
