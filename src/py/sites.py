import os
import json
from re import compile, sub
from time import time, sleep
from collections import deque
from traceback import print_exc
from cachetools import LRUCache
from datetime import datetime
from pathlib import Path
from random import choice, randint
from typing import (
    Any,
    Callable,
    Dict,
    Iterator,
    List,
    MutableSequence,
    Optional,
    Tuple,
    Union,
)
from collections import deque
from datetime import datetime
from enum import IntEnum
from pathlib import Path
from random import choice, randint
from typing import Any, Callable, Dict, Iterator, List, MutableSequence, Optional, Tuple

import numpy as np
import tomli
import zarr as za


def load_publishing_deps():
    global BloomFilter, FBApi, Reddit, Subreddit, TwitterApi, blacklist
    from bloom_filter2 import BloomFilter
    from facepy import GraphAPI as FBApi

    # social
    from praw import Reddit
    from praw.models.reddit.subreddit import Subreddit
    from twitter.api import Api as TwitterApi


import blacklist
import config as cfg

SITES_CONFIG = cfg.SITES_CONFIG
SITES_DOMAINS = {}
import log
import proxies_pb as pb
import utils as ut
import scheduler as sched
from utils import ZarrKey, load_zarr, save_zarr

SITES = LRUCache(10)


class Topic(IntEnum):
    Slug = 0
    Name = 1
    PubDate = 2
    PubCount = 3
    UnpubCount = 4


class TopicState:
    slug: str
    name: str
    pub_date: datetime
    pub_count: int
    unpub_count: int

    def __init__(self, slug="", name="", pub_date: Any = 0, pub_count=0, unpub_count=0):
        self.slug = slug
        self.name = name
        self.pub_date = pub_date
        self.pub_count = pub_count
        self.unpub_count = unpub_count

    def __str__(self):
        return f"""
        slug: {self.slug}
        name: {self.name}
        date: (datetime.fromtimestamp(self.pub_date) if isinstance(self.pub_date, float) else self.pub_date)
        pub_count: {self.pub_count}
        unpub_count: {self.unpub_count}
        """


def name_from_domain(domain):
    try:
        if not SITES_DOMAINS:
            SITES_DOMAINS.update(load_sites())
        return SITES_DOMAINS.get(domain, [""])[0]
    except:
        return ""


def read_sites_config(sitename: str, ensure=False, force=False):
    global SITES_CONFIG
    if SITES_CONFIG is None:
        SITES_CONFIG = {}
    if force or not SITES_CONFIG.get(sitename):
        config_path = cfg.SITES_CONFIG_DIR / (sitename + ".toml")
        try:
            if not config_path.exists():
                raise OSError(f"Config file not found at path {config_path}.")
            with open(config_path, "rb") as f:
                SITES_CONFIG[sitename] = tomli.load(f)
        except Exception as e:
            print(e)
            config_path.touch()
            SITES_CONFIG[sitename] = {}
    if ensure:
        assert isinstance(SITES_CONFIG, dict)
        assert sitename in SITES_CONFIG, f"Site name config is empty."
    return SITES_CONFIG.get(sitename, {})


from enum import Enum


class Job(Enum):
    parse = -1
    feed = -1
    reddit = 60 * 60 * 24
    twitter = 60 * 60 * 2
    facebook = 60 * 60 * 4


SITES_PATH = cfg.CONFIG_DIR / "sites.json"


def load_sites(strict=False):
    """SITES.json is a mapping of `domain` => `port`
    where the port is the local port that is serving the website."""
    if not SITES_PATH.exists():
        raise OSError(f"Path not found: {SITES_PATH}, create it manually.")
    with open(SITES_PATH, "r") as f:
        return json.load(f)


class Site:
    _config: dict
    _tl_config: dict
    _name: str

    topics_arr: Optional[za.Array] = None
    topics_dict: Dict[str, str] = {}
    topics_index: Dict[str, int] = {}
    new_topics_enabled: bool = False
    is_subsite: bool = False
    topics_sync_freq = 3600
    has_reddit = False
    has_twitter = False
    twitter_url = ""
    has_facebook = False
    fb_page_url = ""
    _last_twitter: float = 0
    _last_facebook: float = 0
    _last_reddit: float = 0
    _fb_use_source_url = False

    _topics = None
    _slugs = None

    def __init__(self, sitename="", publishing=False):
        self._name = sitename
        self._config = read_sites_config(sitename)
        if not self._config:
            raise ValueError(f"Config not found for site {sitename}.")
        self.site_dir = cfg.DATA_DIR / "sites" / sitename
        self.req_cache_dir = self.site_dir / "cache"
        if publishing:
            load_publishing_deps()
            self.img_bloom = BloomFilter(
                max_elements=10**8,
                error_rate=0.01,
                filename=(self.site_dir / "bloom_images.bin", -1),
            )

        self.blacklist_path = self.site_dir / "blacklist.txt"
        self.blacklist = blacklist.load_blacklist(self)

        self.topics_dir = self.site_dir / "topics"
        self.topics_idx = self.topics_dir / "index"
        self.new_topics_enabled = self.get_setting("new_topics", False) or False

        self.created = self.get_setting("created", "1970-01-01") or ""
        self.created_dt = datetime.fromisoformat(self.created)
        self.domain = self.get_setting("website_domain", "") or ""
        self.domain_rgx = compile(f"(?:https?:)?//{self.domain}")
        self.url = "https://" + self.domain
        self._domain_title = None
        assert self.domain != "" and isinstance(
            self.domain, str
        ), f"domain not found in site configuration for {self._name}."

        self.last_topic_file = self.topics_dir / "last_topic.json"
        if self.topics_dir.exists():
            self.last_topic_file.touch()
        self._init_data()
        SITES[sitename] = self

        # if its a subdomain, load top level config
        self.is_subsite = len(self.domain.split(".")) > 2
        if self.is_subsite:
            tld = Site.get_tld(self.domain)
            name = name_from_domain(tld)
            if name:
                self._tl_config = read_sites_config(name)
        if sitename != "dev" and publishing:
            self._init_reddit()
            self._init_twitter()
            self._init_facebook()

    @staticmethod
    def get_tld(domain) -> str:
        return ".".join(domain.split(".")[-2:])

    def get_setting(self, k: str, default=None):
        v = self._config.get(k)
        if v is None:
            if self.is_subsite:
                return self._tl_config.get(k, default)
            else:
                return default
        else:
            return v

    def _save_post_time(self, name, val):
        with open(self.site_dir / f"last_{name}.json", "w") as f:
            json.dump(val, f)

    def _load_post_time(self, name):
        try:
            with open(self.site_dir / f"last_{name}.json", "r") as f:
                return json.load(f)
        except:
            return 0

    def _init_facebook(self):
        self._fb_page_id = self.get_setting("facebook_page_id", "") or ""
        if not self._fb_page_id:
            log.warn("Facebook page id not set.")
        self._fb_page_token = self.get_setting("facebook_page_token", "")
        assert (
            self._fb_page_token
        ), "To submit posts to facebook, a page access token is required."
        self._fb_graph = FBApi(self._fb_page_token)
        self._feed_path = self._fb_page_id + "/feed" if self._fb_page_id else ""
        self.has_facebook = True
        self.fb_page_url = "https://facebook.com/" + self._fb_page_id
        self._last_facebook = self._load_post_time("facebook")

    def facebook_post(self, trial=0):
        if trial > 3:
            return
        self.load_topics()
        topic, art = self.choose_article()
        if not isinstance(art, dict):
            log.warn(
                f"Could not choose an article while publishing to fb page, site: {self.name}."
            )
            return
        message = ", ".join(art.get("tags", [])) or art.get("desc", "")
        if self._fb_use_source_url:
            url = art.get("url", "")
            # article_url = self.article_url(art, topic)
            # article_url = sub(self.domain_rgx, "", article_url)
            # article_url = self.domain.split(".")[0] + " " + url
            message = f"{message}\n\nFind more news at,\n{self.title}"
        else:
            url = self.article_url(art, topic)
        try:
            assert pb.is_unproxied()
            self._fb_graph.post(
                self._feed_path,
                # link=self.fb_page_url,
                link=url,
                title=art["title"],
                message=message,
                scrape=True,
            )
            self._last_facebook = time()
            self._save_post_time("facebook", self._last_facebook)
        except Exception as e:
            if "abusive" in str(e):
                log.warn("Using original url for facebook posts.")
                self._fb_use_source_url = True
                self.facebook_post(trial + 1)
            else:
                log.warn(e)

    def facebook_worker(self):
        while True:
            sleep(self.time_until_next(Job.facebook))
            j = sched.apply(self.facebook_post)
            j.wait(60)
            if not j.ready():
                log.warn("facebook post timed out (60s) for site %s", self.name)

    def _init_reddit(self):
        import base64

        reddit_sub = self.get_setting("reddit_subreddit", "")
        if not reddit_sub:
            return
        reddit_id = self.get_setting("reddit_client_id")
        reddit_secret = self.get_setting("reddit_client_secret")
        reddit_user = self.get_setting("reddit_user")
        reddit_psw = self.get_setting("reddit_pass", "") or ""
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
        self._last_reddit = self._load_post_time("reddit")
        self.has_reddit = True

    def choose_subsite(self):
        domains = load_sites().copy()
        while True:
            n_domains = len(domains)
            if not n_domains:
                return
            idx = randint(0, len(domains))
            (dom, _) = domains.pop(idx)
            if self.domain == Site.get_tld(dom):
                return dom

    def choose_article(self):
        self.load_topics()
        topic = self.get_random_topic()
        assert topic is not None
        a = None
        while a is None or not a.get(
            "imageUrl", ""
        ):  # ensure article has an image for socials
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
        self._last_reddit = time()
        self._save_post_time("reddit", self._last_reddit)
        return s

    def reddit_worker(self):
        while True:
            sleep(self.time_until_next(Job.reddit))
            self.reddit_submit()

    def _init_twitter(self):

        consumer_key = self.get_setting("twitter_consumer_key")
        consumer_secret = self.get_setting("twitter_consumer_secret")
        access_key = self.get_setting("twitter_access_token_key")
        access_secret = self.get_setting("twitter_access_token_secret")
        self._twitter_api = TwitterApi(
            consumer_key, consumer_secret, access_key, access_secret
        )
        self.has_twitter = True
        self._last_twitter = self._load_post_time("twitter")
        self.twitter_url = "https://twitter.com/" + (
            self.get_setting("twitter_handle", "") or ""
        )

    def tweet(self):
        topic, a = self.choose_article()
        assert isinstance(self._twitter_api, TwitterApi), "twitter api instance error"
        assert isinstance(a, dict)
        kwargs = {}
        url = self.article_url(a, topic)
        status = "{}: {}".format(a["title"], url)
        kwargs["status"] = status
        media = a.get("imageUrl", "")
        if media:
            kwargs["media"] = media
        if len(url) > 280:
            return
        if len(status) > 280:
            tags = " ".join(*[f"#{t}" for t in a["tag"]])
            status = "{}: {}".format(tags, url)
            if len(status) > 280:
                status = url
        pu = self._twitter_api.PostUpdate(**kwargs)
        self._last_twitter = time()
        self._save_post_time("twitter", self._last_twitter)
        return pu

    def twitter_worker(self):
        while True:
            sleep(self.time_until_next(Job.twitter))
            j = sched.apply(self.tweet)
            j.wait(60)
            if not j.ready():
                log.warn("tweet job timed out (60s) for site %s", self.name)

    def recent_article(self, topic: str):
        arts = self.get_last_done(topic)
        assert isinstance(arts, za.Array), "ZArray instance error"
        max_tries = len(arts)
        tries = 0
        while tries < max_tries:
            a = choice(arts)
            assert isinstance(a, dict)
            if a["slug"] not in self.recent_reddit_submissions:
                break
            tries += 1
        if a["slug"] in self.recent_reddit_submissions:
            return
        return a

    def article_url(self, a: dict, topic=""):
        return "".join(
            (
                "https://",
                self.domain,
                "/",
                a["topic"] or topic,
                "/",
                str(a["page"]),
                "/",
                a["slug"],
            )
        )

    @staticmethod
    def _sources_time(arr: za.Array):
        if not len(arr):
            return 1
        upd = arr.attrs.get("updated")
        if not upd:
            upd = arr.attrs["updated"] = time()
        return max(1, (len(arr) * 20 * 60) - (time() - upd))

    @staticmethod
    def _social_time(last, kind):
        return max(1, kind.value - (time() - last))

    def time_until_next(self, kind: Job, topic: str = ""):
        # How much time should we wait until next job
        match kind:
            case Job.parse:
                assert isinstance(topic, str)
                arts = self.load_articles(topic)
                return self._sources_time(arts)
            case Job.feed:
                assert isinstance(topic, str)
                feeds = self.load_feeds(topic)
                return self._sources_time(feeds)
            case Job.reddit:
                return (
                    self._social_time(self._last_reddit, kind) if self.has_reddit else 1
                )
            case Job.facebook:
                return (
                    self._social_time(self._last_facebook, kind)
                    if self.has_facebook
                    else 1
                )
            case Job.twitter:
                return (
                    self._social_time(self._last_twitter, kind)
                    if self.has_twitter
                    else 1
                )
        return 1

    def topic_feed_interval(self, topic: str):
        # How much time should wait between parse jobs
        feed_count = len(self.load_articles(topic))
        return feed_count * 45

    def topic_dir(self, topic: str):
        return self.topics_dir / topic

    def topic_sources(self, topic: str):
        return self.topic_dir(topic) / "sources"

    @property
    def name(self):
        return self._name

    @property
    def title(self):
        if self._domain_title is None:
            assert self.domain.count(".") == 1
            toplevel, domain = self.domain.split(".")
            self._domain_title = f"{toplevel.title()} dot {domain}"
        return self._domain_title

    def load_articles(self, topic: str, k=ZarrKey.articles, subk: int | str = ""):
        return load_zarr(k=k, subk=subk, root=self.topic_dir(topic))

    def load_feeds(self, topic: str):
        return ut.load_zarr(k=ZarrKey.feeds, root=self.topic_dir(topic))

    def load_done(self, topic: str, pagenum: Optional[int] = None):
        try:
            return (
                self.topic_group(topic)["done"]
                if pagenum is None
                else self.load_articles(topic, k=ZarrKey.done, subk=pagenum)
            )
        except KeyError as e:
            tg = self.topic_group(topic)
            if len(tg) == 0:
                self.reset_topic_data(topic)
                return self.load_done(topic, pagenum)
            else:
                raise e

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
        self.update_article_count(topic)

    def update_pubtime(self, topic: str, pagenum: int):
        page_articles_arr = load_zarr(
            k=ZarrKey.done, subk=str(pagenum), root=self.topic_dir(topic)
        )
        assert page_articles_arr is not None, "pubtime zarr loading error"
        page_articles = page_articles_arr[:]
        for (n, art) in enumerate(page_articles):
            if art is not None:
                art["pubTime"] = int(time())
                page_articles[n] = art
        page_articles_arr[:] = page_articles
        return page_articles_arr

    def save_articles(self, arts: List[dict], topic: str, reset=False):
        checked_arts = [a for a in arts if isinstance(a, dict)]
        save_zarr(
            checked_arts, k=ZarrKey.articles, root=self.topic_dir(topic), reset=reset
        )
        self.update_article_count(topic)

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
        if "feeds" not in grp:
            save_zarr([], k=ZarrKey.feeds, root=self.topic_dir(topic))
        self.update_article_count(topic)


    @property
    def topics(self):
        if self._topics is None:
            tops = self._config.get("topics", [])
            if isinstance(tops, str):
                if tops != "all":
                    tops = tops.split(",")
                else:
                    self.load_topics()
                    tops = list(self.topics_dict.keys())
            self._topics = tops
        return self._topics

    @property
    def slugs(self):
        if self._slugs is None:
            self._slugs = [ut.slugify(s) for s in self.topics]
        return self._slugs


    def load_topics(self, force=False):
        if self.topics_arr is None or force:
            self.topics_arr = load_zarr(
                k=ZarrKey.topics, root=self.topics_idx, dims=2, nocache=force
            )
            if self.topics_arr is None:
                raise IOError(f"Couldn't load topics. for root {self.topics_idx}")
            if len(self.topics_arr) == 0:
                states = []
                for (tp, slug) in zip(self.topics, self.slugs):
                    states.append(
                        np.array(
                            tuple(
                                x
                                for x in TopicState(
                                    name=tp, slug=slug
                                ).__dict__.values()
                            ),
                            dtype=object,
                        )
                    )
                self.topics_arr.append(states)
            if len(self.topics_arr) > 0:
                self.topics_dict = dict(
                    zip(self.topics_arr[:, 0], self.topics_arr[:, 1])
                )
                self.topics_index = dict(
                    zip(self.topics_arr[:, 0], range(0, len(self.topics_arr)))
                )
        return (self.topics_arr, self.topics_dict)

    def _init_data(self):
        if not os.path.exists(self.topics_idx):
            os.makedirs(self.topics_idx)
            load_zarr(k=ZarrKey.topics, root=self.topics_idx, dims=2, overwrite=True)
        self.load_topics()
        tg = self.topic_group(self.slugs[-1])
        if len(list(tg.keys())) == 0:
            for slug in self.slugs:
                tg = self.topic_group(slug)
                if len(list(tg.keys())) == 0:
                    self.reset_topic_data(slug)

    def get_topic_count(self):
        return len(self.topics_dict)

    def status(self, check_count=False):
        for s in self.load_topics()[0]:
            tp = TopicState(*s)
            print(tp)
            if check_count:
                n_done = sum([len(p) for p in self.load_done(tp.slug)])
                assert tp.pub_count == n_done
                assert tp.unpub_count == len(self.load_articles(tp.slug))

    def is_topic(self, topic: str):
        self.load_topics()
        return topic in self.topics_dict

    def is_empty(self, topic: str):
        self.load_topics()
        if not topic:
            return False
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

    def add_topic(self, tp: TopicState):
        assert isinstance(tp, TopicState), "ati: not a topic state"
        (topics, tpset) = self.load_topics()
        if topics.shape == (0, 0):
            topics.resize(0, 5)
        assert ut.slugify(tp.slug) == tp.slug, "ati: slugs should be equal"
        if tp.slug in tpset:
            return
        d = np.asarray([tp.slug, tp.name, tp.pub_date, tp.pub_count, tp.unpub_count])
        topics.append([d])
        tpset[tp.slug] = tp.name
        self.load_topics(force=True)  # update topics_index and topics_dict
        self.reset_topic_data(tp.slug)

    def reset_topics_idx(self, topics):
        """The Topics index holds ordered topics metadata:
        - 0: name
        - 1: descritpion
        - 2: last publication date
        """
        assert isinstance(topics, (tuple, list, np.ndarray))
        assert isinstance(topics[0], (tuple, list, np.ndarray))
        save_zarr(topics, self.topics_idx, ZarrKey.topics, reset=True)
        del ut.PUBCACHE[ut.arr_key(root=self.topics_idx, k=ZarrKey.topics)[0]]
        self.topics_arr = None
        self.topics_dict = dict()

    def delete_topic(self, topic: str):
        if "shutil" not in globals():
            import shutil
        self.load_topics()
        assert self.topics_arr is not None
        cleared = [t for t in self.topics_arr[:] if t[Topic.Slug] != topic]
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
        return self.topics_dict.get(topic, "")

    def get_topic_idx(self, topic) -> int:
        return self.topics_index[topic]

    def get_topic_pubDate(self, topic: str):
        try:
            self.load_topics()
            assert isinstance(self.topics_arr, za.Array)
            assert isinstance(topic, str)
            idx = self.get_topic_idx(topic)
            if idx < len(self.topics_arr):
                t = self.topics_arr[idx, Topic.PubDate]
                if not t:  # when nothing has been published yet
                    return 0
                if t == "0":
                    t = 0
                if not isinstance(t, int):
                    raise ValueError(
                        "date is not a (int) timestamp! (%s: %s)", type(t), t
                    )
                return t
            else:
                return 0
        except:
            print_exc()
            return 0

    def set_topic_pubDate(self, topic: str) -> bool:
        try:
            self.load_topics()
            assert isinstance(self.topics_arr, za.Array)
            assert isinstance(topic, str)
            idx = self.get_topic_idx(topic)
            self.topics_arr[idx, Topic.PubDate] = int(time())
            return True
        except:
            return False

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
        while True:
            if len(self.random_topic_list) == 0:
                self.random_topic_list.extend(self.topics_dict.keys())
                if len(self.random_topic_list) == 0:
                    return ""
            idx = randint(0, len(self.random_topic_list) - 1)
            topic = self.random_topic_list.pop(idx)
            if allow_empty or not self.is_empty(topic):
                return topic

    def remove_broken_articles(self, topic):
        # valid_unpub = []
        def clear_topic(topic):
            arts = self.load_articles(topic=topic)
            for n, a in enumerate(arts):
                if a is not dict:
                    atp = a.get("topic", "")
                    if atp and atp != topic:
                        arts[n] = None

            done = self.load_done(topic)
            for n in range(len(done)):
                page_arts = done[n]
                for n, a in enumerate(page_arts):
                    if a is not dict:
                        atp = a.get("topic", "")
                        if atp and atp != topic:
                            page_arts[n] = None

        try:
            if topic == "all":
                for topic in self.load_topics()[1].keys():
                    clear_topic(topic)
            else:
                clear_topic(topic)
        except:
            log.warn("Couldn't remove broken articles.")

    def topics_watcher(self):
        while True:
            self.load_topics(force=True)
            sleep(self.topics_sync_freq)

    def is_img_new(self, img: str):
        return img in self.img_bloom

    def get_new_img(self, kw: str):
        if "get_images" not in globals():
            from sources import get_images
        images = get_images(kw)
        for img in images:
            if img.url not in self.img_bloom:
                return img

    def _migrate_to_new_size(self) -> za.Array:
        assert isinstance(self.topics_arr, za.Array)
        assert self.topics_arr.ndim == 2
        n_cols = len(Topic)
        if self.topics_arr.shape[1] < n_cols:
            c = self.topics_arr.shape[0]
            self.topics_arr.resize(c, n_cols)  # add
        return self.topics_arr

    def _update_topic_articles(self, t: np.ndarray):
        slug = t[0]
        t[Topic.PubCount] = len(self.load_done(slug))
        # published count
        t[Topic.UnpubCount] = len(self.load_articles(slug))
        return t

    def update_article_count(self, topic=None):
        assert isinstance(self.topics_arr, za.Array)
        arr = self.topics_arr
        if topic is None:  # Update all topics
            for n, t in enumerate(arr):
                arr[n] = self._update_topic_articles(t)
        else:
            idx = self.get_topic_idx(topic)
            t = arr[idx]
            assert (
                t[Topic.Slug] == topic
            ), f"Topic mismatch: {t[Topic.Slug]} != {topic} "
            arr[idx] = self._update_topic_articles(t)

    def sorted_topics(self, key=Topic.UnpubCount, force=False, full=False, rev=False):
        """Returns topics index sorted by the number of unpublished articles of each topics."""
        try:
            arr = self.load_topics(force)[0][:]
            if len(arr) == 0:
                raise ValueError()
            # NOTE: can't sort without coercion
            idx = arr[:, key].astype(np.int64).argsort()
            if rev:  # descending order
                idx = idx[::-1]
            return arr[idx] if full else arr[idx, Topic.Slug]
        except:
            if full:
                return [TopicState(slug=s) for s in self.slugs]
            else:
                return self.slugs


# def init_topic(topic: str):
#     tg = topic_group(topic)
#     arr = np.asarray([], dtype=object)
#     # if ZarrKey.articles not in tg:
#     tg[ZarrKey.articles] = arr
# # if ZarrKey.done not in tg:
#     tg[str(ZarrKey.done) +  "/0"] = arr
# # if ZarrKey.pages not in tg:
#     tg[ZarrKey.pages] = [(0, False)]
