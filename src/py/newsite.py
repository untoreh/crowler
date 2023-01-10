#!/usr/bin/env python3
import argparse
import json
from datetime import datetime
from os import makedirs
from os import symlink as os_symlink
from pathlib import Path
from pprint import pprint
from shutil import copyfile
from sys import stdin
from traceback import print_exc
from typing import NamedTuple

import tomli_w

import config as cfg
import topics as tpm
from sites import SITES_PATH, load_sites
from utils import slugify

SITES = {}


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
    "new_topics": False,
    "twitter_consumer_key": "",
    "twitter_consumer_secret": "",
    "twitter_access_token_key": "",
    "twitter_access_token_secret": "",
    "twitter_handle": "",
    "facebook_page_token": "",
    "facebook_page_id": "",
}


def add_site(domain, name, port):
    assert isinstance(SITES, dict)
    assert isinstance(port, int)
    assert isinstance(name, str)
    SITES[domain] = [name, port]
    bak_file = str(SITES_PATH) + ".bak"
    copyfile(SITES_PATH, bak_file)
    with open(SITES_PATH, "w") as f:
        json.dump(SITES, f)


def unused_port():
    assert isinstance(SITES, dict)
    ports = sorted(SITES.values())
    return ports[-1] + 1


def site_config_path(site_config):
    return cfg.SITES_CONFIG_DIR / (site_config[ConfigKeys.name] + ".toml")


def write_config(site_config):
    success = False
    try:
        config_path = site_config_path(site_config)
        with open(config_path, "wb") as f:
            tomli_w.dump(site_config, f)
        success = True
    finally:
        if success:
            add_site(
                site_config[ConfigKeys.domain],
                site_config[ConfigKeys.name],
                site_config[ConfigKeys.port],
            )


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


def gen_site(domain, cat, force=False):
    if domain in SITES and not force:
        raise ValueError("Domain already present in SITES list.")
    topics = tpm.from_cat(cat)
    slug = slugify(cat)
    assert isinstance(topics, list)
    if not topics:
        raise ValueError(f"No topics found for given domain {domain}.")
    site_config = base_config.copy()
    site_config[ConfigKeys.name] = slug
    site_config[ConfigKeys.domain] = domain
    site_config[ConfigKeys.port] = str(unused_port())
    site_config[ConfigKeys.contact] = "contact@{}.{}".format(*domain.split(".")[-2:])
    site_config[ConfigKeys.topics] = topics
    site_config[ConfigKeys.created] = datetime.now().strftime("%Y-%m-%d")
    tps = tpm.from_slug(slug)
    assert tps.name
    print("Generating symlinks..")

    tld = get_tld(domain)
    if tld != slug:
        makedirs(cfg.DATA_DIR / "sites" / slug, exist_ok=True)
        symlink(cfg.DATA_DIR / "ads", tld, slug)
        symlink(cfg.CONFIG_DIR / "logo", tld, slug)

    print("Type website title:")
    site_config[ConfigKeys.title] = stdin.readline().strip()
    print("Type website description:")
    site_config[ConfigKeys.desc] = stdin.readline().strip()
    pprint(site_config)
    print(f"Write this config? y/n")
    while True:
        ans = stdin.read(1)
        if ans == "y":
            try:
                write_config(site_config)
            finally:
                return site_config
        elif ans == "n":
            print("Aborting")
            exit()
        else:
            print("Type y or n")


def build_match(domain):
    return [{"host": [domain]}]


def build_upstream(from_host, to_host):
    return [{"dial": from_host}, {"dial": to_host}]


def build_reverse_proxy_handle(from_host, to_host):
    [
        {
            "handler": "subroute",
            "routes": [
                {
                    "handle": [
                        {
                            "handler": "reverse_proxy",
                            "upstream": build_upstream(from_host, to_host),
                        }
                    ]
                }
            ],
        }
    ]


def build_route(domain, from_host, to_host):
    return {
        "match": build_match(domain),
        "handle": build_reverse_proxy_handle(from_host, to_host),
    }


def update_caddy_config(caddy_file: str, domain, port, from_host="localhost:80"):
    with open(caddy_file, "r") as f:
        cfg = json.load(f)
    # copy backup after successful read of the main config
    # so we can be sure it's not corrupted
    copyfile(caddy_file, caddy_file + ".bak")
    srv = next(iter(cfg["apps"]["http"]["servers"].values()))
    assert ":80" in srv["listen"]
    routes = srv["routes"]
    assert isinstance(domain, str)
    assert isinstance(port, int)
    to_host = f":{port}"
    new_route = build_route(domain, from_host, to_host)
    routes.append(new_route)
    with open(caddy_file, "w") as f:
        json.dump(f, cfg)


def add_to_supervisor(name):
    supervisor_config = f"""
[program:{name}_server]
directory=%(ENV_PWD)s/
environment=CONFIG_NAME="{name}"
command=./cli startServer
"""
    supervisor_path = cfg.SUPERVISOR_DIR / (name + ".conf")
    with open(supervisor_path, "w") as f:
        f.write(supervisor_config)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-domain", help="The domain name of the new site.", default="")
    parser.add_argument("-cat", help="The category to pull topics from.", default="")
    parser.add_argument("-f", help="Force generation.", default=False)
    parser.add_argument(
        "-caddy",
        help="Caddyfile.json file path.",
        default="/site/config/Caddyfile.json",
    )
    args = parser.parse_args()
    if args.domain == "":
        raise ValueError("Domain can't be empty.")
    if args.cat == "":
        raise ValueError("Category can't be empty.")
    if not Path(args.caddy).exists():
        raise ValueError(f"Caddyfile not found at {args.caddy}")
    SITES = load_sites()
    site_config = gen_site(args.domain, args.cat, force=args.f)
    update_caddy_config(args.caddy, args.domain, site_config[ConfigKeys.port])
    add_to_supervisor(site_config[ConfigKeys.name])
