import os
import re
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from random import choice, randint
from typing import Dict, Iterator, List, MutableSequence, Optional, Sequence, Tuple

import numpy as np
import tomli
import zarr as za
from bloom_filter2 import BloomFilter
from facepy import GraphAPI as FBApi

# social
from praw import Reddit
from praw.models.reddit.subreddit import Subreddit
from twitter.api import Api as TwitterApi

import blacklist
import config as cfg
import log
import proxies_pb as pb
import utils as ut
from utils import ZarrKey, load_zarr, save_zarr

SITES = {}


def read_sites_config(sitename: str, ensure=False, force=False):
    global SITES_CONFIG
    if force or cfg.SITES_CONFIG is None:
        try:
            with open(cfg.SITES_CONFIG_FILE, "rb") as f:
                SITES_CONFIG = tomli.load(f)
        except Exception as e:
            print(e)
            cfg.SITES_CONFIG_FILE.touch()
            SITES_CONFIG = {}
    if ensure:
        assert (
            sitename in SITES_CONFIG
        ), f"Site name provided not found in main config file, {cfg.SITES_CONFIG_FILE}"
    return SITES_CONFIG.get(sitename, {})


class Site:
    _config: dict
    _name: str

    topics_arr: Optional[za.Array] = None
    topics_dict: Dict[str, str] = {}
    new_topics_enabled: bool = False
    topics_sync_freq = 3600
    has_reddit = False
    has_twitter = False
    twitter_url = ""
    has_facebook = False
    fb_page_url = ""

    def __init__(self, sitename=""):
        if not cfg.SITES_CONFIG_FILE.exists():
            return
        self._name = sitename
        self._config = read_sites_config(sitename)
        self.site_dir = cfg.DATA_DIR / "sites" / sitename
        self.req_cache_dir = self.site_dir / "cache"
        self.img_bloom = BloomFilter(
            max_elements=10**8,
            error_rate=0.01,
            filename=(self.site_dir / "bloom_images.bin", -1),
        )
        self.blacklist_path = self.site_dir / "blacklist.txt"
        self.blacklist = blacklist.load_blacklist(self)

        self.topics_dir = self.site_dir / "topics"
        self.topics_idx = self.topics_dir / "index"
        self._topics = self._config.get("topics", [])
        self.new_topics_enabled = self._config.get("new_topics", False)

        self.created = self._config.get("created", "1970-01-01")
        self.created_dt = datetime.fromisoformat(self.created)
        self.domain = self._config.get("domain", "")
        self.domain_rgx = re.compile(f"(?:https?:)?//{self.domain}")
        assert (
            self.domain != ""
        ), f"domain not found in site configuration for {self._name} read from {cfg.SITES_CONFIG_FILE}"

        self.last_topic_file = self.topics_dir / "last_topic.json"
        if self.topics_dir.exists():
            self.last_topic_file.touch()
        self._init_data()
        SITES[sitename] = self

        if sitename != "dev":
            self._init_reddit()
            self._init_twitter()
            self._init_facebook()

    def _init_facebook(self):
        self._fb_page_id = self._config.get("facebook_page_id", "")
        if not self._fb_page_id:
            log.warn("Facebook page id not set.")
        self._fb_page_token = self._config.get("facebook_page_token", "")
        if self._fb_page_id:
            assert (
                self._fb_page_token
            ), "To submit posts to facebook, a page access token is required."
        self._fb_graph = FBApi(self._fb_page_token)
        self._feed_path = self._fb_page_id + "/feed" if self._fb_page_id else ""
        self.has_facebook = True
        self.fb_page_url = "https://facebook.com/" + self._fb_page_id

    def facebook_post(self):
        self.load_topics()
        topic, art = self.choose_article()
        if not isinstance(art, dict):
            log.warn(
                f"Could not choose an article while publishing to fb page, site: {self.name}."
            )
            return
        url = self.article_url(art, topic)
        url = re.sub(self.domain_rgx, "", url)
        dom = self.domain.split(".")[0]
        message = f"{art['desc']}\nContinue at: {dom} {url}"
        try:
            assert pb.is_unproxied()
            self._fb_graph.post(
                self._feed_path,
                link=self.fb_page_url,
                title=art["title"],
                message=message,
            )
        except Exception as e:
            log.warn(e)

    def _init_reddit(self):
        import base64

        reddit_sub = self._config.get("reddit_subreddit", "")
        if not reddit_sub:
            return
        reddit_id = self._config.get("reddit_client_id")
        reddit_secret = self._config.get("reddit_client_secret")
        reddit_user = self._config.get("reddit_user")
        reddit_psw = self._config.get("reddit_pass", "")
        try:
            reddit_psw = base64.b64decode(reddit_psw).decode("utf-8")
        except:
            log.logger.error("Password should be stored b64 encoded")
            return
        assert reddit_sub, "subreddit not defined"
        self._subreddit = Reddit(
            user_agent=self._name,
            client_id=reddit_id,
            client_secret=reddit_secret,
            username=reddit_user,
            password=reddit_psw,
        ).subreddit(reddit_sub)
        self.has_reddit = True

    def choose_article(self):
        self.load_topics()
        topic = self.get_random_topic()
        assert topic is not None
        a = self.recent_article(topic)
        assert a is not None, "no article found"
        return (topic, a)

    recent_reddit_submissions = deque(maxlen=10)

    def reddit_submit(self):
        topic, a = self.choose_article()
        assert isinstance(self._subreddit, Subreddit), "subreddit instance error"
        assert isinstance(a, dict)
        title = a["title"]
        url = self.article_url(a, topic)
        s = self._subreddit.submit(title=title, url=url)
        self.recent_reddit_submissions.append(url)
        return s

    def _init_twitter(self):

        consumer_key = self._config.get("twitter_consumer_key")
        consumer_secret = self._config.get("twitter_consumer_secret")
        access_key = self._config.get("twitter_access_token_key")
        access_secret = self._config.get("twitter_access_token_secret")
        self._twitter_api = TwitterApi(
            consumer_key, consumer_secret, access_key, access_secret
        )
        self.has_twitter = True
        self.twitter_url = "https://twitter.com/" + self._config.get(
            "twitter_handle", ""
        )

    def tweet(self):
        topic, a = self.choose_article()
        assert isinstance(self._twitter_api, TwitterApi), "twitter api instance error"
        assert isinstance(a, dict)
        url = self.article_url(a, topic)
        status = "{}: {}".format(a["title"], url)
        if len(url) > 280:
            return
        if len(status) > 280:
            tags = " ".join(*[f"#{t}" for t in a["tag"]])
            status = "{}: {}".format(tags, url)
            if len(status) > 280:
                status = url
        return self._twitter_api.PostUpdate(status=status)

    def recent_article(self, topic: str):
        arts = self.get_last_done(topic)
        assert isinstance(arts, za.Array), "ZArray instance error"
        assert isinstance(arts, Sequence)
        max_tries = len(arts)
        tries = 0
        while tries < max_tries:
            a = choice(arts)
            if a["slug"] not in self.recent_reddit_submissions:
                break
            tries += 1
        if a["slug"] in self.recent_reddit_submissions:
            return
        return a

    def article_url(self, a: dict, topic=None):
        return "".join(
            ("https://", self.domain, "/", a["topic"] or topic, "/", a["slug"])
        )

    def topic_dir(self, topic: str):
        return self.topics_dir / topic

    def topic_sources(self, topic: str):
        return self.topic_dir(topic) / "sources"

    @property
    def name(self):
        return self._name

    def load_articles(self, topic: str, k=ZarrKey.articles, subk=""):
        return load_zarr(k=k, subk=subk, root=self.topic_dir(topic))

    def load_done(self, topic: str, pagenum: Optional[int] = None):
        return (
            self.topic_group(topic)["done"]
            if pagenum is None
            else self.load_articles(topic, k=ZarrKey.done, subk=pagenum)
        )

    def get_last_done(self, topic: str):
        pagenum = self.get_top_page(topic)
        return self.load_articles(topic, k=ZarrKey.done, subk=pagenum)

    def save_done(self, topic: str, n_processed: int, done: MutableSequence, pagenum):
        assert topic != "", "can't save done articles for an empty topic"
        saved_articles = self.load_articles(topic)
        if saved_articles.shape is not None:
            n_saved = saved_articles.shape[0]
            newsize = n_saved - n_processed
            assert newsize >= 0, "just saved topics should be greater than 0"
            saved_articles.resize(newsize)
        save_zarr(done, k=ZarrKey.done, subk=pagenum, root=self.topic_dir(topic))

    def update_pubtime(self, topic: str, pagenum: int):
        page_articles_arr = load_zarr(
            k=ZarrKey.done, subk=str(pagenum), root=self.topic_dir(topic)
        )
        assert page_articles_arr is not None, "pubtime zarr loading error"
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
        assert idx >= 0, "page idx has to be greater than 0"
        pages = load_zarr(k=ZarrKey.pages, root=self.topic_dir(topic))
        if pages.shape is None:
            print(f"Page {idx}:{topic}@{self.name} not found")
            return
        if pages.shape[0] <= idx:
            pages.resize(idx + 1)
        pages[idx] = (val, final)

    def get_page_size(self, topic: str, idx: int):
        assert idx >= 0, "page idx has to be greater than 0"
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
                assert isinstance(g, za.Group), "zarr group instance error"
                return g
            else:
                raise ValueError(
                    f"topics: Could'nt fetch topic group, {file_path} does not exist."
                )

    def get(self, topic: str):
        return self.topic_group(topic)

    def reset_topic_data(self, topic: str):
        assert topic != "", "the topic exist to be reset"
        print("utils: resetting topic data for topic: ", topic)
        grp = self.topic_group(topic)
        assert isinstance(grp, za.Group), "rtd: zarr group instance error"
        if "done" in grp:
            done = grp["done"]
            assert isinstance(done, za.Group), "rtd2: zarr group instance error"
            done.clear()
        else:
            save_zarr([], k=ZarrKey.done, subk="0", root=self.topic_dir(topic))
        if "pages" in grp:
            pages = grp["pages"]
            assert isinstance(pages, za.Array), "rtd3: zarr array instance error"
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
            self.topics_arr = load_zarr(
                k=ZarrKey.topics, root=self.topics_idx, dims=2, nocache=force
            )
            if self.topics_arr is None:
                raise IOError(f"Couldn't load topics. for root {self.topics_idx}")
            if len(self.topics_arr) > 0:
                self.topics_dict = dict(
                    zip(self.topics_arr[:, 0], self.topics_arr[:, 1])
                )
            else:
                self.topics_dict = {}
        return (self.topics_arr, self.topics_dict)

    def get_topic_count(self):
        return len(self.topics_dict)

    def is_topic(self, topic: str):
        self.load_topics()
        return topic in self.topics_dict

    def is_empty(self, topic: str):
        self.load_topics()
        done = self.load_done(topic)
        return len(done) == 0 or len(done[0]) == 0

    def clear_invalid(self):
        for topic, _, _ in self.load_topics()[0]:
            done = self.load_done(topic)
            tosave = []
            for page in done:
                arts = done[page]
                assert isinstance(arts, za.Array)
                for a in arts:
                    if ut.is_valid_article(a):
                        tosave.append(a)
                arts.resize(len(tosave))
                arts[:] = tosave

    def add_topics_idx(self, tp: List[Tuple[str, str, int]]):
        assert isinstance(tp, list), "ati: list instance error"
        (topics, tpset) = self.load_topics()
        if topics.shape == (0, 0):
            topics.resize(0, 3)
        for t in tp:
            tpslug = t[0]
            assert ut.slugify(tpslug) == tpslug, "ati: slugs should be equal"
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
        assert isinstance(tp, (tuple, list, np.ndarray))
        assert isinstance(tp[0], (tuple, list, np.ndarray))
        tp = np.asarray(tp)
        save_zarr(tp, self.topics_idx, ZarrKey.topics, reset=True)
        del ut.PUBCACHE[ut.arr_key(root=tp, k=ZarrKey.topics)[0]]
        self.topics_arr = None
        self.topics_dict = dict()

    def delete_topic(self, topic: str):
        if "shutil" not in globals():
            import shutil
        self.load_topics()
        assert self.topics_arr is not None
        cleared = [t for t in self.topics_arr[:] if t[0] != topic]
        try:
            shutil.rmtree(self.topic_dir(topic))
        except FileNotFoundError:
            pass
        self.reset_topics_idx(cleared)

    @staticmethod
    def _count_top_page(pages):
        top = len(pages) - 1
        if top == -1:
            return 0
        return top

    def get_top_page(self, topic: str):
        try:
            assert topic
            tg = self.topic_group(topic)
            pages = tg[ZarrKey.pages.name]
            return Site._count_top_page(pages)
        except KeyError:
            log.warn("topic: ", topic, "doesn't have a pages array")
            return 0

    def get_topic_desc(self, topic: str):
        return self.topics_dict[topic]

    def get_topic_pubDate(self, idx: int):
        assert self.topics_arr is not None
        return int(self.topics_arr[idx, 2]) if len(self.topics_arr) > idx else 0

    def set_topic_pubDate(self, idx):
        assert self.topics_arr is not None
        self.topics_arr[idx, 2] = int(time.time())

    def iter_published_articles(self, topic: str) -> Iterator[dict]:
        done = self.load_done(topic)
        top_idx = len(done) - 1
        # previous pages
        for n in range(top_idx):
            for a in done[n]:
                if isinstance(a, dict):
                    yield a

    random_topic_list = list()

    def get_random_topic(self, allow_empty=False):
        assert self.topics_arr is not None
        if len(self.random_topic_list) == 0:
            self.random_topic_list.extend(self.topics_dict.keys())
        while len(self.random_topic_list) > 0:
            idx = randint(0, len(self.random_topic_list) - 1)
            topic = self.random_topic_list.pop(idx)
            if allow_empty or not self.is_empty(topic):
                return topic
        return ""

    def remove_broken_articles(self, topic):
        # valid_unpub = []
        arts = self.load_articles(topic=topic)
        for n, a in enumerate(arts):
            if a is not dict or a.get("topic", "") != topic:
                arts[n] = None
            # if a is not int or a.get("topic", "") != topic:
            #     valid_unpub.append(a)
        # if len(arts) > len(valid_unpub):
        #     self.save_articles(valid_unpub, topic=topic, reset=True)

        # published
        done = self.load_done(topic)
        top_idx = len(done) - 1
        for n in range(top_idx):
            # valid_pub = []
            page_arts = done[n]
            for n, a in enumerate(page_arts):
                if a is not dict or a.get("topic", "") != topic:
                    page_arts[n] = None
                # if isinstance(a, dict):
                #     valid_pub.append(a)
            # if len(done[n]) > len(valid_pub):
            #     save_zarr(valid_pub, k=ZarrKey.done, subk=n, root=self.topic_dir(topic))

    def topics_watcher(self):
        while True:
            self.load_topics(force=True)
            time.sleep(self.topics_sync_freq)

    def is_img_new(self, img: str):
        return img in self.img_bloom

    def get_new_img(self, kw: str):
        if "get_images" not in globals():
            from .sources import get_images
        images = get_images(kw)
        for img in images:
            if img.url not in self.img_bloom:
                return img


# def init_topic(topic: str):
#     tg = topic_group(topic)
#     arr = np.asarray([], dtype=object)
#     # if ZarrKey.articles not in tg:
#     tg[ZarrKey.articles] = arr
# # if ZarrKey.done not in tg:
#     tg[str(ZarrKey.done) +  "/0"] = arr
# # if ZarrKey.pages not in tg:
#     tg[ZarrKey.pages] = [(0, False)]
