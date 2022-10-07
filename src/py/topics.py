import json
import os
import random
import time

from pytrends.request import TrendReq
from textblob import TextBlob

import adwords_keywords as adk
import config as cfg
import log
import proxies_pb as pb
import utils as ut
from sites import Site

CATEGORIES = None
_CAT_FILE = cfg.DATA_DIR / "google" / "categories.json"
_KEYWORDS = None
if os.path.exists(cfg.TOPICS_BLACKLIST):
    with open(cfg.TOPICS_BLACKLIST, "r") as f:
        BLACKLIST = set(f.read().split("\n"))
else:
    BLACKLIST = set()
MIN_SENTIMENT = 0.17


def load_categories(reset=False):
    global CATEGORIES, DONE
    if CATEGORIES == None:
        if not reset and os.path.exists(_CAT_FILE):
            with open(_CAT_FILE, "r") as f:
                CATEGORIES = json.load(f)
        else:
            with pb.http_opts():
                pytrends = TrendReq(
                    hl="en",
                    tz=360,
                    # proxies=pb.PROXIES,
                    retries=2,
                    backoff_factor=0.1,
                    timeout=20,
                )
            cats = pytrends.categories()
            os.makedirs(os.path.dirname(_CAT_FILE))
            CATEGORIES = flatten_categories(cats=cats)
            with open(_CAT_FILE, "w") as f:
                json.dump(CATEGORIES, f)


def flatten_categories(flat=[], cats=CATEGORIES):
    for c in cats["children"]:
        if "children" in c:
            flatten_categories(flat, c)
        else:
            flat.append(c["name"])
    return flat


def get_last_topic(site: Site):
    with open(site.last_topic_file, "r") as lt:
        try:
            last_topic = json.load(lt)
        except:
            last_topic = {"name": "", "time": 0}
    return last_topic


def set_last_topic(site: Site, data):
    with open(site.last_topic_file, "w") as lt:
        json.dump(data, lt)


def get_category(site: Site, force=False):
    last_topic = get_last_topic(site)
    # if the last topic processing ended correctly the topic should be indexed
    tpslug = ut.slugify(last_topic["name"])
    if (not force) and (last_topic["name"] and tpslug and not site.is_topic(tpslug)):
        return last_topic["name"]
    if CATEGORIES is None:
        load_categories()
    assert CATEGORIES is not None
    n = random.randrange(len(CATEGORIES))
    v = CATEGORIES.pop(n)
    set_last_topic(site, {"name": v, "time": int(time.time())})
    with open(_CAT_FILE, "w") as f:
        json.dump(CATEGORIES, f)
    return v


def gen_topic(site: Site, check_sentiment=True, max_cat_tries=3):
    global _KEYWORDS
    cat_tries = 0
    while cat_tries < max_cat_tries:
        cat = get_category(site)
        if cat not in BLACKLIST:
            break
        cat_tries += 1
    tpslug = ut.slugify(cat)
    topic_dir = site.topic_dir(tpslug)
    try:
        os.makedirs(topic_dir)
    except:
        pass
    suggestions = suggest(cat)
    assert suggestions is not None
    sugstr = "\n".join(suggestions)
    sentiment = TextBlob(sugstr).sentiment.polarity
    if (not check_sentiment) or (sentiment >= MIN_SENTIMENT):
        with open(topic_dir / "list.txt", "w") as f:
            f.write(sugstr)
        site.add_topics_idx([(tpslug, cat, 0)])
        # clear last topic since we saved
        return tpslug
    else:
        log.warn(
            f"topic: generation skipped for {cat}, sentiment low {sentiment} < {MIN_SENTIMENT}"
        )
        set_last_topic(site, {"name": "", "time": 0})
        return None


def new_topic(site: Site, max_tries=3):
    tries = 0
    while tries < max_tries:
        tpslug = gen_topic(site, check_sentiment=True)
        if tpslug is not None:
            return tpslug
        tries += 1


def suggest(topic: str):
    assert topic
    global _KEYWORDS
    with pb.http_opts():
        if _KEYWORDS is None:
            _KEYWORDS = adk.Keywords()
        sugs = []
        kws = [topic]
        while len(sugs) < 20:
            s = _KEYWORDS.suggest(kws[:20], langloc=None)
            if len(s) == 0:
                break
            sugs.extend(s)
            kws = s
    return list(dict.fromkeys(sugs))  ## dedup


def save_kws(site: Site, topic: str, kws: list):
    topic_dir = site.topic_dir(topic)
    if not kws:
        kws.extend(suggest(topic))
    with open(topic_dir / "list.txt", "w") as f:
        f.seek(0)
        f.write("\n".join(kws))
