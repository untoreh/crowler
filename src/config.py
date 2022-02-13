import os
from os.path import isdir, dirname
from pathlib import Path
import warnings
import requests_cache

requests_cache.install_cache("cache")

if os.getenv("PYTHON_NO_WARNINGS"):
    warnings.simplefilter("ignore")

PROXIES_ENABLED = False
PROXIES_EP = "http://127.0.0.1:8080/proxies.json"
STATIC_PROXY_EP = "http://127.0.0.1:8082"
STATIC_PROXY = True
PROXY_DICT = {"http": STATIC_PROXY_EP, "https": STATIC_PROXY_EP}


def setproxies(p=STATIC_PROXY_EP):
    os.environ["HTTPS_PROXY"] = os.environ["HTTP_PROXY"] = os.environ[
        "http_proxy"
    ] = os.environ["https_proxy"] = p


REQ_TIMEOUT = 15
# How many concurrent requests
POOL_SIZE = 8

DATA_DIR = Path("../data")
assert isdir(Path(dirname(DATA_DIR)) / ".venv")

TOPICS_DIR = DATA_DIR / "topics"
KW_HISTORY = "history"
# how many keywords to try for extracting source links from search engines
KW_SAMPLE_SIZE = 10
# how many source links to process for extracting feeds and articles
SRC_MAX_TRIES = 5

SPACY_MODEL = "en_core_web_sm"
TAGS_MAX_LEN = 4

# from importlib import import_module
# from functools import wraps

# def withmodule(mod, a=None):
#     def decoratormodule(f):
#         @wraps(f)
#         def wrapper(*args, **kwargs):
#             gl = globals()
#             name = a if a is not None else mod
#             if name not in gl or gl[name] is None:
#                 gl[name] = import_module(mod)
#             return f(*args, **kwargs)
#         return wrapper
#     return decoratormodule
