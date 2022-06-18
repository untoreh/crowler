from pytrends.request import TrendReq
import os, json, random, time

import adwords_keywords as adk
import config as cfg
import utils as ut

CATEGORIES = None
_CAT_FILE = cfg.DATA_DIR / "google" / "categories.json"
_KEYWORDS = None
LAST_TOPIC_FILE = cfg.TOPICS_DIR / "last_topic.json"


def load_categories(reset=False):
    global CATEGORIES, DONE
    if CATEGORIES == None:
        if not reset and os.path.exists(_CAT_FILE):
            with open(_CAT_FILE, "r") as f:
                CATEGORIES = json.load(f)
        else:
            pytrends = TrendReq(
                hl="en",
                tz=360,
                # proxies=pb.PROXIES,
                retries=2,
                backoff_factor=0.1,
                timeout=cfg.REQ_TIMEOUT,
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


def get_last_topic():
    with open(LAST_TOPIC_FILE, "r") as lt:
        try:
            last_topic = json.load(lt)
        except:
            last_topic = {"name": "", "time": 0}
    return last_topic


def set_last_topic(data):
    with open(LAST_TOPIC_FILE, "w") as lt:
        json.dump(data, lt)


def get_category():
    last_topic = get_last_topic()
    # if the last topic processing ended correctly the topic should be indexed
    tpslug = ut.slugify(last_topic["name"])
    if tpslug and not ut.is_topic(tpslug):
        return last_topic["name"]
    if CATEGORIES is None:
        load_categories()
    assert CATEGORIES is not None
    n = random.randrange(len(CATEGORIES))
    v = CATEGORIES.pop(n)
    set_last_topic({"name": v, "time": int(time.time())})
    with open(_CAT_FILE, "w") as f:
        json.dump(CATEGORIES, f)
    return v


def new_topic():
    global _KEYWORDS
    cat = get_category()
    tpslug = ut.slugify(cat)
    topic_path = cfg.TOPICS_DIR / tpslug
    try:
        os.makedirs(topic_path)
    except:
        pass
    suggestions = suggest(cat)
    assert suggestions is not None
    with open(topic_path / "list.txt", "w") as f:
        f.write("\n".join(suggestions))
    ut.add_topics_idx([(tpslug, cat, 0)])
    # clear last topic since we saved
    return tpslug

def suggest(topic: str):
    assert topic
    global _KEYWORDS
    cfg.setproxies(None)
    if _KEYWORDS is None:
        _KEYWORDS = adk.Keywords()
    sugs = []
    kws = [topic]
    while len(sugs) < 20:
        s = _KEYWORDS.suggest(kws[:20], langloc=None)
        sugs.extend(s)
        kws = s
    cfg.setproxies()
    return list(dict.fromkeys(sugs))  ## dedup

def save_kws(topic: str, kws: list):
    topic_path = cfg.TOPICS_DIR / topic
    sugs = suggest(topic)
    with open(topic_path / "list.txt", "w") as f:
        f.seek(0)
        f.write("\n".join(kws))
