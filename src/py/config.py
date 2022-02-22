import os
from os.path import isdir, dirname
from pathlib import Path
import warnings
import pycurl
from trafilatura import settings as traset
from user_agent import generate_user_agent
import copy

if os.getenv("PYTHON_NO_WARNINGS"):
    warnings.simplefilter("ignore")

PROXIES_ENABLED = False
PROXIES_EP = "http://127.0.0.1:8080/proxies.json"
STATIC_PROXY_EP = "http://127.0.0.1:8082"
STATIC_PROXY = True
PROXY_DICT = {"http": STATIC_PROXY_EP, "https": STATIC_PROXY_EP}

if "CURL_CLASS" not in globals():
    CURL_CLASS = copy.deepcopy(pycurl.Curl)
def curlproxy():
    c = CURL_CLASS()
    ua = generate_user_agent()
    c.setopt(pycurl.PROXY, STATIC_PROXY_EP)
    c.setopt(pycurl.SSL_VERIFYHOST, 0)
    c.setopt(pycurl.SSL_VERIFYPEER, 0)
    # self.setopt(pycurl.PROXYTYPE, pycurl.PROXYTYPE_SOCKS5_HOSTNAME)
    c.setopt(pycurl.CONNECTTIMEOUT, REQ_TIMEOUT)
    c.setopt(pycurl.USERAGENT, ua)
    traset.DEFAULT_CONFIG.set("DEFAULT", "USER_AGENTS", ua)
    return c


PROXY_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")

def setproxies(p=STATIC_PROXY_EP):
    if p:
        for name in PROXY_VARS:
            os.environ[name] = p
        pycurl.Curl = curlproxy
    else:
        for name in PROXY_VARS:
            del os.environ[name]
            pycurl.Curl = CURL_CLASS


REQ_TIMEOUT = 15
# How many concurrent requests
POOL_SIZE = 8

DATA_DIR = Path(os.path.realpath("../../data"))
assert isdir(Path(dirname(DATA_DIR)) / ".venv")

TOPICS_DIR = DATA_DIR / "topics"
KW_HISTORY = "history"
# how many keywords to try for extracting source links from search engines
KW_SAMPLE_SIZE = 10
# how many source links to process for extracting feeds and articles
SRC_MAX_TRIES = 5
REQ_CACHE_DIR = DATA_DIR / "cache"

DEFAULT_LANG = "en"
SPACY_MODEL = "en_core_web_sm"
TAGS_MAX_LEN = 4
