#!/usr/bin/env python3

from typing import Annotated, MutableSequence, Optional
from config import BLACKLIST_PATH
from urllib.parse import urlparse

BLACKLIST: Annotated[
    Optional[set], "Domain list to exclude from sources and parsing."
] = None


def load_blacklist():
    global BLACKLIST
    with open(BLACKLIST_PATH, "r") as f:
        BLACKLIST = set(f.read())

def exclude(k):
    u = urlparse(k)
    if u.hostname is None:
        return False
    else:
        return u.hostname not in BLACKLIST


def exclude_blacklist(data: MutableSequence) -> MutableSequence:
    if BLACKLIST is None:
        load_blacklist()
    return list(filter(exclude, data))
