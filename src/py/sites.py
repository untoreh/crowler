from typing import Dict, List, MutableSequence, Optional, Tuple
from pathlib import Path
import os

import tomli
import time
import zarr as za
import numpy as np
from random import choice

import config as cfg
import utils as ut
from utils import ZarrKey, save_zarr, load_zarr, strtobool

import blacklist

SITES = {}


def read_sites_config(sitename: str):
    global SITES_CONFIG
    if cfg.SITES_CONFIG is None:
        try:
            with open(cfg.SITES_CONFIG_FILE, "rb") as f:
                SITES_CONFIG = tomli.load(f)
        except Exception as e:
            print(e)
            cfg.SITES_CONFIG_FILE.touch()
            SITES_CONFIG = {}
    assert (
        sitename in SITES_CONFIG
    ), f"Site name provided not found in main config file, {cfg.SITES_CONFIG_FILE}"
    return SITES_CONFIG[sitename]


class Site:
    _config: dict
    _name: str

    topics_arr: Optional[za.Array] = None
    topics_dict: Dict[str, str] = {}
    new_topics_enabled: bool = False
    topics_sync_freq = 3600

    def __init__(self, sitename=""):
        self._name = sitename
        self._config = read_sites_config(sitename)
        self.site_dir = cfg.DATA_DIR / "sites" / sitename
        self.req_cache_dir = self.site_dir / "cache"
        self.blacklist_path = self.site_dir / "blacklist.txt"
        self.blacklist = blacklist.load_blacklist(self)
        self.topics_dir = self.site_dir / "topics"
        self.topics_idx = self.topics_dir / "index"
        self._topics = self._config.get("topics", [])
        self.new_topics_enabled = strtobool(self._config.get("new_topics", "false"))
        self.last_topic_file = self.topics_dir / "last_topic.json"
        if self.topics_dir.exists():
            self.last_topic_file.touch()
        self._init_data()
        SITES[sitename] = self

    def topic_dir(self, topic: str):
        return self.topics_dir / topic

    def topic_sources(self, topic: str):
        return self.topic_dir(topic) / "sources"

    @property
    def name(self):
        return self._name

    def load_articles(self, topic: str, k=ZarrKey.articles):
        return load_zarr(k=k, subk="", root=self.topic_dir(topic))

    def load_done(self, topic: str):
        return self.load_articles(topic, k=ZarrKey.done)

    def save_done(self, topic: str, n_processed: int, done: MutableSequence, pagenum):
        assert topic != ""
        saved_articles = self.load_articles(topic)
        if saved_articles.shape is not None:
            n_saved = saved_articles.shape[0]
            newsize = n_saved - n_processed
            assert newsize >= 0
            saved_articles.resize(newsize)
        save_zarr(done, k=ZarrKey.done, subk=pagenum, root=self.topic_dir(topic))

    def update_pubtime(self, topic: str, pagenum: int):
        page_articles_arr = load_zarr(
            k=ZarrKey.done, subk=str(pagenum), root=self.topic_dir(topic)
        )
        assert page_articles_arr is not None
        page_articles = page_articles_arr[:]
        for (n, art) in enumerate(page_articles):
            if art is not None:
                art["pubTime"] = int(time.time())
                page_articles[n] = art
        page_articles_arr[:] = page_articles
        return page_articles_arr

    def save_articles(self, arts: List[dict], topic: str, reset=False):
        checked_arts = [a for a in arts if isinstance(a, dict)]
        save_zarr(
            checked_arts, k=ZarrKey.articles, root=self.topic_dir(topic), reset=reset
        )

    def update_page_size(self, topic: str, idx: int, val, final=False):
        assert idx >= 0
        pages = load_zarr(k=ZarrKey.pages, root=self.topic_dir(topic))
        if pages.shape is None:
            print(f"Page {idx}:{topic}@{self.name} not found")
            return
        if pages.shape[0] <= idx:
            pages.resize(idx + 1)
        pages[idx] = (val, final)

    def get_page_size(self, topic: str, idx: int):
        assert idx >= 0
        pages = load_zarr(k=ZarrKey.pages, root=self.topic_dir(topic))
        if pages.shape is None:
            print(f"Page {idx}:{topic} not found")
            return
        if pages.shape[0] <= idx:
            return None
        return pages[idx]

    def topic_group(self, topic):
        cache_key = (topic, self.topics_dir)
        try:
            return ut.PUBCACHE[cache_key]
        except KeyError:
            file_path = ut.get_file_path(
                Path(topic), self.topics_dir, ext=None, as_json=False
            )
            za.open_group(file_path, mode="a")
            if Path(file_path).exists():
                g = ut.PUBCACHE[cache_key] = za.open_group(file_path, mode="a")
                assert isinstance(g, za.Group)
                return g
            else:
                raise ValueError(
                    f"topics: Could'nt fetch topic group, {file_path} does not exist."
                )

    def get(self, topic: str):
        return self.topic_group(topic)

    def reset_topic_data(self, topic: str):
        assert topic != ""
        print("utils: resetting topic data for topic: ", topic)
        grp = self.topic_group(topic)
        assert isinstance(grp, za.Group)
        if "done" in grp:
            done = grp["done"]
            assert isinstance(done, za.Group)
            done.clear()
        else:
            save_zarr([], k=ZarrKey.done, subk="0", root=self.topic_dir(topic))
        if "pages" in grp:
            pages = grp["pages"]
            assert isinstance(pages, za.Array)
            pages.resize(0)
        else:
            save_zarr([], k=ZarrKey.pages, root=self.topic_dir(topic))
        if "articles" not in grp:
            save_zarr([], k=ZarrKey.articles, root=self.topic_dir(topic))

    def _init_data(self):
        if not os.path.exists(self.topics_idx):
            os.makedirs(self.topics_idx)
            load_zarr(k=ZarrKey.topics, root=self.topics_idx, dims=2, overwrite=True)

    def load_topics(self, force=False):
        if self.topics_arr is None or force:
            self.topics_arr = load_zarr(k=ZarrKey.topics, root=self.topics_idx, dims=2, nocache=force)
            if self.topics_arr is None:
                raise IOError(f"Couldn't load topics. for root {self.topics_idx}")
            if len(self.topics_arr) > 0:
                self.topics_dict = dict(
                    zip(self.topics_arr[:, 0], self.topics_arr[:, 1])
                )
            else:
                self.topics_dict = {}
        return (self.topics_arr, self.topics_dict)

    def is_topic(self, topic: str):
        self.load_topics()
        return topic in self.topics_dict

    def add_topics_idx(self, tp: List[Tuple[str, str, int]]):
        assert isinstance(tp, list)
        (topics, tpset) = self.load_topics()
        if topics.shape == (0, 0):
            topics.resize(0, 3)
        for t in tp:
            tpslug = t[0]
            assert ut.slugify(tpslug) == tpslug
            if tpslug in tpset:
                continue
            d = np.asarray(t)
            topics.append([d])
            tpset[tpslug] = t[1]
            self.reset_topic_data(tpslug)

    def reset_topics_idx(self, tp):
        """The Topics index holds ordered topics metadata:
        - 0: name
        - 1: descritpion
        - 2: last publication date
        """
        assert isinstance(tp, (tuple, list))
        assert isinstance(tp[0], (tuple, list))
        tp = np.asarray(tp)
        save_zarr(tp, self.topics_idx, ZarrKey.topics, reset=True)
        self.topics_arr = None
        self.topics_dict = dict()

    @staticmethod
    def _count_top_page(pages):
        top = len(pages) - 1
        if top == -1:
            return 0
        return top

    def get_top_page(self, topic: str):
        assert topic
        tg = self.topic_group(topic)
        pages = tg[ZarrKey.pages.name]
        return Site._count_top_page(pages)

    def get_top_articles(self, topic: str):
        t = self.topic_group(topic)
        pages = t[ZarrKey.pages.name]
        assert isinstance(pages, za.Array)
        if len(pages) > 0:
            n_articles = pages[-1][0]
            return t[ZarrKey.articles.name][-n_articles:]
        else:
            return np.empty(0)

    def get_topic_desc(self, topic: str):
        return self.topics_dict[topic]

    def get_topic_pubDate(self, idx: int):
        assert self.topics_arr is not None
        return int(self.topics_arr[idx, 2]) if len(self.topics_arr) > idx else 0

    def set_topic_pubDate(self, idx):
        assert self.topics_arr is not None
        self.topics_arr[idx, 2] = int(time.time())

    def iter_topic_articles(self, topic: str):
        tg = self.topic_group(topic)
        # previous pages
        for pagenum in tg[ZarrKey.done.name]:
            done = self.load_done(topic)
            for a in done[pagenum]:
                yield a
        # last page
        for a in tg[ZarrKey.articles.name]:
            yield a

    def get_random_topic(self):
        assert self.topics_arr is not None
        return choice(self.topics_arr)[0]

    def remove_broken_articles(self, topic):
        valid = []
        for a in enumerate(self.load_articles(topic=topic)):
            if a is not int:
                valid.append(a)
        self.save_articles(valid, topic=topic, reset=True)

    def topicsWatcher(self):
        while True:
            self.load_topics(force=True)
            time.sleep(self.topics_sync_freq)


# def init_topic(topic: str):
#     tg = topic_group(topic)
#     arr = np.asarray([], dtype=object)
#     # if ZarrKey.articles not in tg:
#     tg[ZarrKey.articles] = arr
# # if ZarrKey.done not in tg:
#     tg[str(ZarrKey.done) +  "/0"] = arr
# # if ZarrKey.pages not in tg:
#     tg[ZarrKey.pages] = [(0, False)]
