import os, socket
from pathlib import Path
import warnings
import pycurl
from trafilatura import settings as traset, downloads as tradl
from user_agent import generate_user_agent
import copy
import json

if os.getenv("PYTHON_NO_WARNINGS"):
    warnings.simplefilter("ignore")

PROXIES_ENABLED = True
PROXIES_EP = "http://127.0.0.1:8080/proxies.json"
STATIC_PROXY_EP = "socks5://localhost:8877"
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
    c.setopt(pycurl.USERAGENT, ua)
    traset.DEFAULT_CONFIG.set("DEFAULT", "USER_AGENTS", ua)
    traset.TIMEOUT = REQ_TIMEOUT
    tradl.TIMEOUT = REQ_TIMEOUT
    return c


PROXY_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")


def setproxies(p=STATIC_PROXY_EP):
    if p:
        for name in PROXY_VARS:
            os.environ[name] = p
        pycurl.Curl = curlproxy
    else:
        for name in PROXY_VARS:
            if name in os.environ:
                del os.environ[name]
            pycurl.Curl = CURL_CLASS


def set_socket_timeout(timeout):
    socket.setdefaulttimeout(timeout)


set_socket_timeout(5)

REQ_TIMEOUT = 20
# How many concurrent requests
POOL_SIZE = os.cpu_count()

DATA_DIR = Path(
    os.path.realpath(
        "./data"
        if os.path.exists("./data")
        else "../../data"
        if os.path.exists("../../data")
        else Path(os.getenv("PROJECT_DIR", "")) / "data"
    )
)
assert DATA_DIR is not None  # and isdir(Path(dirname(DATA_DIR)) / ".venv")

PROXIES_DIR = DATA_DIR / "proxies"
TOPICS_DIR = DATA_DIR / "topics"
TOPICS_IDX = TOPICS_DIR / "index"
KW_HISTORY = "history"
# how many keywords to try for extracting source links from search engines
KW_SAMPLE_SIZE = 10
# How much should a source job take
KW_SEARCH_TIMEOUT = 60
# how many source links to process for extracting feeds and articles
SRC_MAX_TRIES = 2
REMOVE_SOURCES = json.loads(os.getenv("REMOVE_SOURCES", "true").lower())
REQ_CACHE_DIR = DATA_DIR / "cache"

DEFAULT_LANG = "en"
SPACY_MODEL = "en_core_web_sm"
TAGS_MAX_LEN = 4

ART_MIN_LEN = (
    3000  # minimum article len (5 avg chars per 500 words + 500 chars for pre-cleanups)
)
PROFANITY_THRESHOLD = 0.5
# The maximum number of articles/feeds to store `unprocessed` for each topic
# When cap is reached queue gets discarded as FIFO.
MAX_BACKLOG_SIZE = 100

BLACKLIST_PATH = DATA_DIR / "blacklist.txt"
