#!/usr/bin/env python3
#
import unicodedata
import re
import config as cfg
import os
import json
import logging
logger = logging.getLogger()

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

def save_file(contents, node, ext="txt", root=cfg.DATA_DIR, mode='w+', as_json=True, newline=False):
    if root and not os.path.isdir(root):
        assert not os.path.isfile(root)
        os.makedirs(root)
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
