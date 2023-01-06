#!/usr/bin/env python3
from datetime import datetime
from os import symlink as os_symlink
from sys import stdin
import json
import argparse
from pathlib import Path
from shutil import copyfile
from typing import NamedTuple
from traceback import print_exc

from praw.models.listing.mixins import base
import tomli_w
import config as cfg
from utils import slugify
import topics as tpm


class ConfigKeys(NamedTuple):
    name = "website_name"
    domain = "website_domain"
    scheme = "website_scheme"
    port = "website_port"
    title = "website_title"
    desc = "website_description"
    contact = "website_contact"
    pages = "website_custom_pages"
    created = "created"
    topics = "topics"


base_config = {
    ConfigKeys.name: "",
    ConfigKeys.domain: "",
    ConfigKeys.scheme: "https://",
    ConfigKeys.port: "",
    ConfigKeys.title: "",
    ConfigKeys.desc: "",
    ConfigKeys.contact: "",
    ConfigKeys.pages: "dmca,terms-of-service,privacy-policy",
    ConfigKeys.created: "",
    ConfigKeys.topics: "",
    "new_topics": True,
    "twitter_consumer_key": "",
    "twitter_consumer_secret": "",
    "twitter_access_token_key": "",
    "twitter_access_token_secret": "",
    "twitter_handle": "",
    "facebook_page_token": "",
    "facebook_page_id": "",
}

# `sites.json` is a mapping of `domain` => `port`
# where the port is the local port that is serving the website
sites_path = cfg.CONFIG_DIR / "sites.json"
if not sites_path.exists():
    raise OSError(f"Path not found: {sites_path}, create it manually.")
with open(sites_path, "r") as f:
    SITES = json.load(f)


def add_domain(domain, port):
    assert isinstance(SITES, dict)
    assert isinstance(port, int)
    SITES[domain] = port
    bak_file = str(sites_path) + ".bak"
    copyfile(sites_path, bak_file)
    with open(sites_path, "w") as f:
        json.dump(SITES, f)


def unused_port():
    assert isinstance(SITES, dict)
    ports = sorted(SITES.values())
    return ports[-1] + 1


def write_config(site_config):
    success = False
    try:
        site_config_path = cfg.SITES_CONFIG_DIR / (
            site_config[ConfigKeys.name] + ".toml"
        )
        with open(site_config_path, "wb") as f:
            tomli_w.dump(site_config, f)
        success = True
    finally:
        if success:
            add_domain(site_config[ConfigKeys.domain], site_config[ConfigKeys.port])


def get_tld(domain):
    spl = domain.split(".")
    if len(spl) > 2:
        return spl[-2]
    else:
        return "default"


def symlink(base: Path, tld, slug):
    try:
        os_symlink(base / tld, base / slug)
        return True
    except:
        print_exc()
        print("Couldn't create symlink")
        return False


def gen_site(domain, cat):
    if domain in SITES:
        raise ValueError("Domain already present in SITES list.")
    topics = tpm.from_cat(cat)
    slug = slugify(cat)
    assert isinstance(topics, list)
    if not topics:
        raise ValueError(f"No topics found for given domain {domain}.")
    site_config = base_config.copy()
    site_config[ConfigKeys.name] = slug
    site_config[ConfigKeys.domain] = domain
    site_config[ConfigKeys.port] = unused_port()
    site_config[ConfigKeys.contact] = "contact@{}.{}".format(*domain.split(".")[-2:])
    site_config[ConfigKeys.topics] = topics
    site_config[ConfigKeys.created] = datetime.now().strftime("%Y-%m-%d")
    tps = tpm.from_slug(slug)
    assert tps.name
    print("Generating symlinks..")
    import os

    tld = get_tld(domain)
    if tld != slug:
        symlink(cfg.DATA_DIR, tld, slug)
        symlink(cfg.DATA_DIR / "ads", tld, slug)

    print("Type website title:")
    site_config[ConfigKeys.title] = stdin.readline()
    print("Type website description:")
    site_config[ConfigKeys.desc] = stdin.readline()
    print(f"Write this config? y/n\n{site_config}")
    while True:
        ans = stdin.read()
        if ans == "y":
            try:
                write_config(site_config)
            finally:
                break
        elif ans == "n":
            print("Aborting")
            exit()
        else:
            print("Type y or n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-domain", help="The domain name of the new site.", default="")
    parser.add_argument("-cat", help="The category to pull topics from.", default="")
    args = parser.parse_args()
    if args.domain == "":
        raise ValueError("Domain can't be empty.")
    if args.cat == "":
        raise ValueError("Category can't be empty.")
    gen_site(args.domain, args.cat)
