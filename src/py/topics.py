from pytrends.request import TrendReq
import os, json, random, time

import config as cfg
import adwords_keywords as adk
import utils as ut

CATEGORIES = None
_CAT_FILE = cfg.DATA_DIR / "google" / "categories.json"
_KEYWORDS = adk.Keywords()
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


def get_category():
    with open(LAST_TOPIC_FILE, "a+") as lt:
        last_topic = json.load(lt)
        # if the last topic processing ended correctly the topic should be indexed
        if not ut.is_topic(last_topic["name"]):
            return last_topic
        if CATEGORIES is None:
            load_categories()
        assert CATEGORIES is not None
        n = random.randrange(len(CATEGORIES))
        v = CATEGORIES.pop(n)
        json.dump({"name": v, "time": int(time.time())}, lt)
        with open(_CAT_FILE, "w") as f:
            json.dump(CATEGORIES, f)
    return v


def new_topic():
    cat = get_category()
    tpslug = ut.slugify(cat)
    topic_path = cfg.TOPICS_DIR / tpslug
    os.makedirs(topic_path)
    suggestions = _KEYWORDS.suggest([cat])
    assert suggestions is not None
    with open(topic_path / "list.txt", "w") as f:
        f.write("\n".join(suggestions))
    ut.add_topics_idx([(tpslug, cat, 0)])
    # clear last topic since we saved
    return tpslug
