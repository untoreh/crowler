import json
from typing import List
import os
import random
import time

from pytrends.request import TrendReq
from textblob import TextBlob
import re

import adwords_keywords as adk
import config as cfg
import log
import proxies_pb as pb
import utils as ut
from sites import Site, TopicState

CATEGORIES: List | None = None
_ALL_CAT_FILE = cfg.DATA_DIR / "google" / "all_categories.json"
_CAT_FILE = cfg.DATA_DIR / "google" / "categories.json"
_KEYWORDS = None
if os.path.exists(cfg.TOPICS_BLACKLIST):
    with open(cfg.TOPICS_BLACKLIST, "r") as f:
        BLACKLIST = set(f.read().split("\n"))
else:
    BLACKLIST = set()
MIN_SENTIMENT = 0.17


def load_categories(reset=False, allcats=False):
    global CATEGORIES, DONE
    if CATEGORIES == None and not reset:
        if not allcats and not reset and os.path.exists(_CAT_FILE):
            with open(_CAT_FILE, "r") as f:
                CATEGORIES = json.load(f)
                return CATEGORIES
        elif allcats and not reset and os.path.exists(_ALL_CAT_FILE):
            with open(_ALL_CAT_FILE, "r") as f:
                return json.load(f)
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
            os.makedirs(os.path.dirname(_CAT_FILE), exist_ok=True)
            if allcats:
                if not os.path.exists(_ALL_CAT_FILE):
                    with open(_ALL_CAT_FILE, "w") as f:
                        json.dump(cats, f)
            if reset:
                CATEGORIES = flatten_categories(cats=cats)
                with open(_CAT_FILE, "w") as f:
                    json.dump(CATEGORIES, f)
                return CATEGORIES
            else:
                return cats


def flatten_categories(flat: List = [], cats=CATEGORIES):
    assert isinstance(cats, dict)
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


def gen_topic(
    site: Site, check_sentiment=True, max_cat_tries=3, topic: TopicState | None = None
):
    global _KEYWORDS
    cat_tries = 0
    if topic is None:
        topic = TopicState()
        while cat_tries < max_cat_tries:
            topic.name = get_category(site)
            if topic.name not in BLACKLIST:
                break
            cat_tries += 1
        topic.slug = ut.slugify(topic.name)

    topic_dir = site.topic_dir(topic.slug)
    try:
        os.makedirs(topic_dir)
    except:
        pass
    suggestions = suggest(topic.name)
    assert suggestions is not None
    sugstr = "\n".join(suggestions)

    def finalize():
        with open(topic_dir / "list.txt", "w") as f:
            f.write(sugstr)
        site.add_topic(topic)
        return topic.slug

    if not check_sentiment:
        return finalize()
    else:
        sentiment = TextBlob(sugstr).sentiment.polarity
        if sentiment >= MIN_SENTIMENT:
            return finalize()
        else:
            log.warn(
                f"topic: generation skipped for {topic.name}, sentiment low {sentiment} < {MIN_SENTIMENT}"
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


years_rgx = re.compile("\d{4}")


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
            for n in range(len(s)):  # remove years
                s[n] = re.sub(years_rgx, "", s[n])
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


def from_slug(slug: str, cats=None):
    """Return the full name of a topic, from its slug."""
    if cats is None:
        cats = load_categories(allcats=True)
    assert isinstance(cats, dict)
    name = cats.get("name", "")
    if ut.slugify(name) == slug:
        return TopicState(name=name, slug=slug)
    else:
        for c in cats.get("children", []):
            ts = from_slug(slug, c)
            if ts.slug:
                return ts
    return TopicState()

all_cat = "All categories"

def from_cat(cat: str, cats=None):
    """Return the list of children categories given a main one, or the main one if it has no children."""
    if cats is None:
        cats = load_categories(allcats=True)
        cat = ut.slugify(cat)
    assert isinstance(cats, dict)
    name = cats.get("name", "")
    if ut.slugify(name) == cat:
        cdr = cats.get("children", [])
        result = []
        if len(cdr) == 0:
            result.append(name)
        else:
            for c in cdr:
                result.append(c.get("name", ""))
        return result
    else:
        for c in cats.get("children", []):
            val = from_cat(cat, c)
            if val:
                if name != all_cat:
                    val.append(name)
                return val
