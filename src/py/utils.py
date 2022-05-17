#!/usr/bin/env python3
#
from ctypes import ArgumentError
from pathlib import Path
import json
import os
import re
import unicodedata
import numpy as np
from re import finditer
from enum import Enum
from time import sleep
from typing import MutableSequence, Optional, TypeAlias, Union, Tuple, List, Dict
from distutils.util import strtobool
from random import choice

from cachetools import LRUCache
import numcodecs
import zarr as za
from numcodecs import Blosc
from trafilatura import fetch_url as _fetch_url

import config as cfg

from zict import Func, LRU

# data
compressor = Blosc(cname="zstd", clevel=2, shuffle=Blosc.BITSHUFFLE)
codec = numcodecs.Pickle()
TOPICS: Optional[za.Array] = None
TPDICT: Dict[str, str] = dict()
PUBCACHE = LRUCache(2**20)
OVERWRITE_FLAG = strtobool(os.getenv("RESET_ARTICLES", "False"))


def init_lru(n=1000):
    zict_storage = za.DirectoryStore(cfg.REQ_CACHE_DIR)
    zict_compressor = Func(compressor.encode, compressor.decode, zict_storage)
    zict_codec = Func(codec.encode, codec.decode, zict_compressor)
    return LRU(n, zict_codec)


LRU_CACHE = init_lru()


def somekey(d, *keys):
    v = None
    for k in keys:
        if v := d.get(k):
            break
    return v


def fetch_data(url, *args, delay=0.3, backoff=0.3, depth=0, fromcache=True, **kwargs):
    if fromcache:
        try:
            data = LRU_CACHE[url]
        except KeyError:
            data = _fetch_url(url)
    else:
        data = _fetch_url(url)
    if data is None and depth < 4:
        # try an http request 2 times
        if depth == 2:
            url = url.replace("https://", "http://", 1)
        sleep(delay)
        data = fetch_data(url, delay=delay + backoff, depth=depth + 1, fromcache=False)
        LRU_CACHE[url] = data
    return data


# From a list of keywords
def read_file(f, ext="txt", delim="\n"):
    path = f"{f}.{ext}" if ext is not None else f
    if os.path.isfile(path):
        with open(path, "r") as f:
            read = f.read()
            if ext == "txt":
                content = read.split(delim)
            elif ext == "json":
                content = json.loads(read)
            else:
                content = read
            return content


def get_file_path(node, root, ext, as_json):
    if root and not os.path.isdir(root):
        assert not os.path.isfile(root)
        os.makedirs(root)
    if as_json and ext is None:
        ext = "json"
    file_name = f"{node}.{ext}" if ext is not None else node
    file_path = file_name if root is None else (root / file_name)
    return file_path


def save_file(
    contents, node, ext=None, root=cfg.DATA_DIR, mode="w+", as_json=True, newline=False
):
    file_path = get_file_path(node, root, ext, as_json)
    with open(file_path, mode) as f:
        if as_json:
            r = json.dump(contents, f, default=str)
        else:
            r = f.write(contents)
        if newline:
            f.write("\n")
        return r


def slugify(value, allow_unicode=False):
    """
    Taken from https://github.com/django/django/blob/master/django/utils/text.py
    Convert to ASCII if 'allow_unicode' is False. Convert spaces or repeated
    dashes to single dashes. Remove characters that aren't alphanumerics,
    underscores, or hyphens. Convert to lowercase. Also strip leading and
    trailing whitespace, dashes, and underscores.
    """
    value = str(value)
    if allow_unicode:
        value = unicodedata.normalize("NFKC", value)
    else:
        value = (
            unicodedata.normalize("NFKD", value)
            .encode("ascii", "ignore")
            .decode("ascii")
        )
    value = re.sub(r"[^\w\s-]", "", value.lower())
    return re.sub(r"[-\s]+", "-", value).strip("-_")


def dedup(l):
    return list(dict.fromkeys(l))


def splitStr(string, sep="\s+"):
    # warning: does not yet work if sep is a lookahead like `(?=b)`
    if sep == "":
        return (c for c in string)
    else:
        return (_.group(1) for _ in finditer(f"(?:^|{sep})((?:(?!{sep}).)*)", string))


def dirsbydate(path):
    """Returns a list of directories at path sorted by date (oldest first, newest last)."""
    dirs = list(os.scandir(path))
    return sorted(dirs, key=lambda d: d.stat().st_ctime)

class ZarrKey(Enum):
    # articles to be published
    articles = "articles"
    # feeds to fetch for articles
    feeds = "feeds"
    # published posts
    done = "done"
    # keeps the number of posts in each page
    pages = "pages"
    # stores the topics list and the last update timestamp for each one
    topics = "topics"

def _wrap_path(root):
    return os.path.normpath(os.path.sep + str(root) + os.path.sep)


def save_zarr(
    contents,
    root,
    k: ZarrKey = ZarrKey.articles,
    subk="",
    reset=False,
):
    if len(contents) > cfg.MAX_BACKLOG_SIZE:
        contents = contents[-cfg.MAX_BACKLOG_SIZE :]
    try:
        data = np.asarray(contents)
    except:
        raise ValueError("Contents provided can't be converted to numpy array.")
    # append to existing array or create new one
    if not reset:
        # NOTE: there might be some recursion going on here :)
        try:
            # print(f"loading zarr: {k}, subk: {subk}, root: {root}")
            z = load_zarr(k, subk=subk, root=root)
        except Exception as e:
            if isinstance(e, TypeError):
                # print("loading zarr: type error")
                z = load_zarr(k, subk=subk, root=root, overwrite=True)
            else:
                # logger.warning(f"Couldn't save content root: '{root}', k: '{k}', subk: '{subk}'")
                raise e
        max_append = cfg.MAX_BACKLOG_SIZE - len(z)
        if len(data) > max_append:
            # print(f"loading zarr: resizing data to {max_append}")
            data = data[-max_append:]
        # print(f"loading zarr: appending {len(data)} elements")
        z.append(data)
    else:
        store = za.DirectoryStore(_wrap_path(root))
        path = ZarrKey(k).name
        if subk != "":
            path += f"/{subk}"
        za.save_array(
            store=store,
            arr=data,
            path=path,
            object_codec=codec,
            compressor=compressor,
            dtype=object,
        )


def load_articles(topic_path=None, topic=None, k=ZarrKey.articles):
    if topic_path is None:
        if topic is None:
            raise ArgumentError(
                "Specify either topic or topic_path to load published articles."
            )
        else:
            topic_path = cfg.TOPICS_DIR / topic
    return load_zarr(k=k, subk="", root=topic_path)


def load_done(*args, **kwargs):
    kwargs["k"] = ZarrKey.done
    return load_articles(*args, **kwargs)


def save_done(topic: str, n_processed: int, done: MutableSequence, pagenum):
    """This function is called from nim, after publishing articles."""
    assert topic != ""
    topic_path = cfg.TOPICS_DIR / topic
    saved_articles = load_articles(topic_path)
    if saved_articles.shape is not None:
        n_saved = saved_articles.shape[0]
        newsize = n_saved - n_processed
        assert newsize >= 0
        saved_articles.resize(newsize)
    save_zarr(done, k=ZarrKey.done, subk=pagenum, root=topic_path)


def save_articles(arts: List[dict], topic: str, reset=False):
    topic_path = cfg.TOPICS_DIR / topic
    save_zarr(arts, k=ZarrKey.articles, root=topic_path, reset=reset)


def update_page_size(topic: str, idx: int, val, final=False):
    assert idx >= 0
    topic_path = cfg.TOPICS_DIR / topic
    pages = load_zarr(k=ZarrKey.pages, root=topic_path)
    if pages.shape is None:
        print(f"Page {idx}:{topic} not found")
        return
    if pages.shape[0] <= idx:
        pages.resize(idx + 1)
    pages[idx] = (val, final)


def get_page_size(topic: str, idx: int):
    assert idx >= 0
    topic_path = cfg.TOPICS_DIR / topic
    pages = load_zarr(k=ZarrKey.pages, root=topic_path)
    if pages.shape is None:
        print(f"Page {idx}:{topic} not found")
        return
    if pages.shape[0] <= idx:
        return None
    return pages[idx]


def load_zarr(
    k=ZarrKey.articles, subk="", root=cfg.DATA_DIR, dims=1, overwrite=OVERWRITE_FLAG
):
    path = ZarrKey(k).name
    if subk != "":
        path += f"/{subk}"
    cache_key = (path, root)
    try:
        return PUBCACHE[cache_key]
    except KeyError:
        store = za.DirectoryStore(_wrap_path(root))
        try:
            z = PUBCACHE[cache_key] = za.open_array(store=store, path=path, mode="a")
            return z
        except (OSError, ValueError, TypeError) as e:
            if not overwrite:
                raise e
            else:
                stub = np.empty(tuple(0 for _ in range(dims)))
                save_zarr(stub, root, k, subk, reset=True)
                z = PUBCACHE[cache_key] = za.open_array(
                    store=store, path=path, mode="a"
                )
                return z


def topic_group(topic, root=cfg.TOPICS_DIR):
    cache_key = (topic, root)
    try:
        return PUBCACHE[cache_key]
    except KeyError:
        file_path = get_file_path(Path(topic), root, ext=None, as_json=False)
        if os.path.exists(file_path):
            g = PUBCACHE[cache_key] = za.open_group(file_path, mode="a")
            assert isinstance(g, za.Group)
            return g
        else:
            raise ValueError("topics: Could'nt fetch topic group")


def get_topic(tp, **kwargs):
    return topic_group(tp, **kwargs)


def reset_topic_data(topic: str):
    assert topic != ""
    grp = topic_group(topic)
    assert isinstance(grp, za.Group)
    if "done" in grp:
        done = grp["done"]
        assert isinstance(done, za.Group)
        done.clear()
    else:
        save_zarr([], k=ZarrKey.done, subk="0", root=(cfg.TOPICS_DIR / topic))
    if "pages" in grp:
        pages = grp["pages"]
        assert isinstance(pages, za.Array)
        pages.resize(0)


def load_topics():
    global TOPICS, TPDICT
    if TOPICS is None:
        TOPICS = load_zarr(k=ZarrKey.topics, root=cfg.TOPICS_IDX, dims=2)
        if TOPICS is None:
            raise IOError("Couldn't load topics.")
        TPDICT = dict(zip(TOPICS[:, 0], TOPICS[:, 1]))
    return (TOPICS, TPDICT)


TopicsList: TypeAlias = List[Tuple[str, str]]


def add_topics_idx(tp: TopicsList):
    global TOPICS, TPDICT
    assert isinstance(tp, list)
    (topics, tpset) = load_topics()
    for t in tp:
        d = np.asarray(t)
        topics.append(d)
        tpset[t[0]] = t[1]


def reset_topics_idx(tp):
    global TOPICS, TPDICT
    assert isinstance(tp, list)
    tp = np.asarray(tp)
    save_zarr(tp, cfg.TOPICS_IDX, ZarrKey.topics, reset=True)
    TOPICS = None
    TPDICT = dict()


def _count_top_page(pages):
    top = len(pages) - 1
    if top == -1:
        return 0
    return top


def get_top_page(topic: str):
    topic_path = cfg.TOPICS_DIR / topic
    pages = load_zarr(k=ZarrKey.pages, root=topic_path)
    return _count_top_page(pages)


def get_top_articles(topic: str):
    t = topic_group(topic)
    pages = t[ZarrKey.pages.name]
    assert isinstance(pages, za.Array)
    if len(pages) > 0:
        n_articles = pages[-1][0]
        return t[ZarrKey.articles.name][-n_articles:]
    else:
        return np.empty(0)


def get_topic_desc(topic: str):
    return TPDICT[topic]


def iter_topic_articles(topic: str):
    tg = topic_group(topic)
    # previous pages
    for pagenum in tg[ZarrKey.done.name]:
        done = load_done()
        for a in done:
            yield a
    # last page
    for a in tg[ZarrKey.articles.name]:
        yield a

def get_random_topic():
    assert TOPICS is not None
    return choice(TOPICS)[0]
