#!/usr/bin/env python3

from typing import MutableSequence
from urllib.parse import urlparse
from pathlib import Path

def load_blacklist(site):
    try:
        with open(site.blacklist_path, "r") as f:
            return set(f.read())
    except:
        Path(site.blacklist_path).touch()

def exclude(site, k):
    u = urlparse(k)
    if u.hostname is None:
        return False
    else:
        return u.hostname not in site.blacklist

def exclude_sources(site, k): return exclude(site, k["url"])

def exclude_blacklist(site, data: MutableSequence, f=exclude) -> MutableSequence:
    if site.blacklist is None:
        site.blacklist = load_blacklist(site)
    return list(filter(f, data))

def exclude_blacklist_sources(*args):
    return exclude_blacklist(*args, f=exclude_sources)
