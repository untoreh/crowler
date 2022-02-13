#!/usr/bin/env python3
#
import unicodedata
import re
import config as cfg
import os
import sys
import json
import logging
from re import finditer
from contextlib import redirect_stdout, redirect_stderr, contextmanager, ExitStack
import os
from newsplease import SimpleCrawler

sc = SimpleCrawler()

logger = logging.getLogger()
logger.setLevel(logging.WARNING)

handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.WARNING)
handler.setFormatter(logging.Formatter("%(name)s - %(levelname)s - %(message)s"))
logger.addHandler(handler)


def fetch_data(url):
    data = sc.fetch_url(url)
    if data is None:
        raise ValueError(f"Failed crawling feed url: {url}.")
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


def save_file(
    contents, node, ext=None, root=cfg.DATA_DIR, mode="w+", as_json=True, newline=False
):
    if root and not os.path.isdir(root):
        assert not os.path.isfile(root)
        os.makedirs(root)
    if as_json and ext is None:
        ext = "json"
    file_name = f"{node}.{ext}"
    file_path = file_name if root is None else root / file_name
    with open(file_path, mode) as f:
        if as_json:
            r = json.dump(contents, f)
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
    "Returns a list of directories at path sorted by date (oldest first, newest last)."
    dirs = list(os.scandir(path))
    return sorted(dirs, key=lambda d: d.stat().st_ctime)
