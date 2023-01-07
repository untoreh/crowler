#!/usr/bin/env python3

import os
from functools import partial
from pathlib import Path
from typing import MutableSequence
from urllib.parse import urlparse


def load_blacklist(site):
    try:
        with open(site.blacklist_path, "r") as f:
            return set(f.read())
    except:
        blacklist_path = Path(site.blacklist_path)
        if not blacklist_path.exists():
            os.makedirs(blacklist_path.parent, exist_ok=True)
        blacklist_path.touch()
        return set()


def exclude(site, k):
    u = urlparse(k)
    if u.hostname is None:
        return False
    else:
        return u.hostname not in site.blacklist


def exclude_sources(site, k):
    return exclude(site, k["url"])


def exclude_blacklist(site, data: MutableSequence, f=exclude) -> MutableSequence:
    f = partial(f, site)
    if site.blacklist is None:
        site.blacklist = load_blacklist(site)
    return list(filter(f, data))


def exclude_blacklist_sources(site, *args):
    return exclude_blacklist(site, *args)
