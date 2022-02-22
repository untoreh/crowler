#!/usr/bin/env python3
#
from pathlib import Path
import json
import logging
import os
import re
import sys
import unicodedata
import numpy as np
from re import finditer
from enum import Enum
from retry import retry

import numcodecs
import zarr as za
from numcodecs import Blosc
from trafilatura import fetch_url as _fetch_url

import config as cfg

import pickle
from zict import File, Func, LRU

# data
compressor = Blosc(cname="zstd", clevel=2, shuffle=Blosc.BITSHUFFLE)
codec = numcodecs.Pickle()
def init_lru(n=1000):
    # zict_storage = File(cfg.REQ_CACHE_DIR, mode='a')
    zict_storage = za.DirectoryStore(cfg.REQ_CACHE_DIR)
    zict_compressor = Func(compressor.encode, compressor.decode, zict_storage)
    zict_codec = Func(codec.encode, codec.decode, zict_compressor)
    return LRU(n, zict_codec)
LRU_CACHE = init_lru()


# logging
logger = logging.getLogger()
logger.setLevel(getattr(logging, os.getenv("PYTHON_DEBUG", "warning").upper()))

handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.WARNING)
handler.setFormatter(logging.Formatter("%(name)s - %(levelname)s - %(message)s"))
logger.addHandler(handler)

def somekey(d, *keys):
    for k in keys:
        if v := d.get(k):
            break
    return v


@retry(ValueError, tries=3, delay=1, backoff=0.3, logger=None)
def fetch_data(url, *args, **kwargs):
    try:
        data = LRU_CACHE[url]
    except KeyError:
        data = _fetch_url(url)
        if data is None:
            raise ValueError(f"Failed crawling feed url: {url}.")
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
        ext = ".json"
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
    articles = "articles"
    feeds = "feeds"


def _wrap_path(root):
    return os.path.normpath(os.path.sep + str(root) + os.path.sep)


def save_zarr(contents, k: ZarrKey = ZarrKey.articles, root=cfg.DATA_DIR, reset=False):
    path = ZarrKey(k).name
    try:
        data = np.asarray(contents)
    except:
        raise ValueError("Contents provided can't be converted to numpy array.")
    store = za.DirectoryStore(_wrap_path(root))
    # append to existing array or create new one
    if not reset:
        # NOTE: there might be some recursion going on here :)
        z = load_zarr(k, root=root)
        z.append(data)
    else:
        za.save_array(
            store=store,
            arr=data,
            path=path,
            object_codec=codec,
            compressor=compressor,
            dtype=object,
        )


def load_zarr(k=ZarrKey.articles, root=cfg.DATA_DIR):
    path = ZarrKey(k).name
    store = za.DirectoryStore(_wrap_path(root))
    try:
        return za.open_array(store=store, path=path)
    except:
        save_zarr([], k, root=root)
        return za.open_array(store=store, path=path)


def zarr_articles_group(topic, root=cfg.TOPICS_DIR):
    file_path = get_file_path(Path(topic) / "articles", root, ext=None, as_json=False)
    return za.open_group(file_path)
