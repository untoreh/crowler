#!/usr/bin/env python3
#
import imghdr
import json
import os
import re
import unicodedata
from difflib import SequenceMatcher
from enum import Enum
from io import BytesIO
from re import finditer
from time import sleep, time
from typing import Dict, Optional
from urllib.request import urlopen

import numcodecs
import numpy as np
import zarr as za
from numcodecs import Blosc

import config as cfg
import proxies_pb as pb
from httputils import fetch_data
from config import strtobool
from cachetools import LRUCache

# data
compressor = Blosc(cname="zstd", clevel=2, shuffle=Blosc.BITSHUFFLE)
codec = numcodecs.Pickle()
TOPICS: Optional[za.Array] = None
TPDICT: Dict[str, str] = dict()
PUBCACHE = LRUCache(16)
OVERWRITE_FLAG = strtobool(os.getenv("RESET_ARTICLES", "False"))


def somekey(d, *keys):
    v = None
    for k in keys:
        if v := d.get(k):
            break
    return v


slash_rgx = re.compile(r"/+")
from pathlib import Path



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


def is_img_url(url: str):
    try:
        with urlopen(url) as f:
            what = imghdr.what(BytesIO(f.read(12)))
            return bool(what)
    except:
        return False


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


def splitStr(string, sep="\\s+"):
    # warning: does not yet work if sep is a lookahead like `(?=b)`
    if sep == "":
        return (c for c in string)
    else:
        return (_.group(1) for _ in finditer(f"(?:^|{sep})((?:(?!{sep}).)*)", string))


def similar(a, b):
    return SequenceMatcher(None, a, b).ratio()


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


def is_valid_article(a):
    return isinstance(a, dict) and a.get("content", "") != ""


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
        if k == ZarrKey.articles:
            contents = [c for c in contents if isinstance(c, dict)]
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
        z.attrs["updated"] = time()
    else:
        store = za.DirectoryStore(_wrap_path(root))
        path = ZarrKey(k).name
        if subk != "":
            path += f"/{subk}"
        kwargs = {
            "store": store,
            "path": path,
            "object_codec": codec,
            "compressor": compressor,
            "dtype": object,
        }
        if len(data) == 0:
            kwargs["shape"] = (0, 3) if k == ZarrKey.topics else (0,)
            zfun = za.empty
        else:
            kwargs["arr"] = data
            zfun = za.save_array
        zfun(**kwargs)


def arr_key(k=ZarrKey.articles, subk="", root=cfg.DATA_DIR):
    path = ZarrKey(k).name
    if subk != "":
        path += f"/{subk}"
    cache_key = (path, root)
    return cache_key, path


def load_zarr(
    k=ZarrKey.articles,
    subk="",
    root=cfg.DATA_DIR,
    dims=1,
    overwrite=OVERWRITE_FLAG,
    nocache=False,
):
    cache_key, path = arr_key(k, subk, root)
    if nocache:
        del PUBCACHE[cache_key]
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
