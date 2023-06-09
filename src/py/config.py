import json
import os
import sys
import warnings
from pathlib import Path

from proxies_pb import REQ_TIMEOUT
from scheduler import POOL_SIZE
assert isinstance(POOL_SIZE, int)

if os.getenv("LIBPYTHON_PATH", "").endswith("d.so"):
    sys.path.extend(
        [
            "/opt/python-dbg/lib/python310.zip",
            "/opt/python-dbg/lib/python3.10",
            "/opt/python-dbg/lib/python3.10/lib-dynload",
            "/opt/python-dbg/lib/python3.10/site-packages",
        ]
    )
if os.getenv("PYTHON_NO_WARNINGS"):
    warnings.simplefilter("ignore")

def strtobool(val):
    """Convert a string representation of truth to true (1) or false (0).
    True values are 'y', 'yes', 't', 'true', 'on', and '1'; false values
    are 'n', 'no', 'f', 'false', 'off', and '0'.  Raises ValueError if
    'val' is anything else.
    """
    val = val.lower()
    if val in ("y", "yes", "t", "true", "on", "1"):
        return 1
    elif val in ("n", "no", "f", "false", "off", "0"):
        return 0
    else:
        raise ValueError("invalid truth value %r" % (val,))

PROJECT_DIR = Path(
    os.path.realpath(
        "./"
        if os.path.exists("./src")
        else "../../"
        if os.path.exists("../../src")
        else Path(os.getenv("PROJECT_DIR", ""))
    )
)

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
CONFIG_DIR = DATA_DIR.parent / "config"

SUPERVISOR_DIR = CONFIG_DIR / "supervisor.d"
PROXIES_DIR = DATA_DIR / "proxies"
PROXIES_FILES = [ PROXIES_DIR / f"{prx}proxies.json" for prx in ("socks5", "socks4", "http")]
SOCKS5PEERS_FILE = PROXIES_DIR / "socks5peers.txt"
SOCKS4PEERS_FILE = PROXIES_DIR / "socks4peers.txt"
HTTPPEERS_FILE = PROXIES_DIR / "httppeers.txt"
# how many keywords to try for extracting source links from search engines
KW_SAMPLE_SIZE = 4
# How much should a source job take
KW_SEARCH_TIMEOUT = 240
# how many source links to process for extracting feeds and articles
SRC_MAX_TRIES = 2
REMOVE_SOURCES = json.loads(os.getenv("REMOVE_SOURCES", "true").lower())
CACHE_DIR = DATA_DIR / "cache"

DEFAULT_LANG = "en"
SPACY_MODEL = "en_core_web_sm"
TAGS_MAX_LEN = 4

ART_MIN_LEN = 500  # minimum article len
PROFANITY_THRESHOLD = 0.5
# The maximum number of articles/feeds to store `unprocessed` for each topic
# When cap is reached queue gets discarded as FIFO.
MAX_BACKLOG_SIZE = 100

NEW_TOPICS_ENABLED = strtobool(
    os.getenv("NEW_TOPICS_ENABLED", "False")
)  # If the job server should keep adding new topics to the current website
NEW_TOPIC_FREQ = 3600 * 8  # Delay between adding new topics

SITES_CONFIG_DIR = CONFIG_DIR / "sites"
SITES_DIR = DATA_DIR / "sites"

SITES_CONFIG = None
TOPICS_BLACKLIST = DATA_DIR / "topics-blacklist.txt"

