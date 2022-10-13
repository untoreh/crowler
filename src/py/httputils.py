#!/usr/bin/env python3
from pathlib import Path
from time import sleep
from typing import Dict, NamedTuple

import numcodecs

# import pycurl
import pycurl_requests as requests
import zarr as za
from numcodecs import Blosc
from trafilatura.downloads import _handle_response
from trafilatura.settings import DEFAULT_CONFIG as traf_config
from zict import LRU, Func

import config as cfg
import proxies_pb as pb

codec = numcodecs.Pickle()
compressor = Blosc(cname="zstd", clevel=2, shuffle=Blosc.BITSHUFFLE)


class Response(NamedTuple):
    url: str
    status: int
    headers: Dict[str, str]
    data: str | bytes


def init_lru(n=1000):
    zict_storage = za.DirectoryStore(cfg.CACHE_DIR)
    zict_compressor = Func(compressor.encode, compressor.decode, zict_storage)
    zict_codec = Func(codec.encode, codec.encode, zict_compressor)
    return LRU(n, zict_codec)


LRU_CACHE = init_lru()


def send_request(depth, meth, url, headers, body):
    try:
        with pb.http_opts(proxy=depth, timeout=4):
            return requests.request(meth, url, headers=headers, data=body, verify=False)
    except:
        # print(e)
        pass


def fetch(url, depth, *args, meth="GET", headers={}, body="", decode=False, **kwargs):
    resp = ""
    req = send_request(depth, meth, url, headers=headers, body=body)
    if isinstance(req, requests.models.Response):
        resp = Response(req.url or url, req.status_code or 0, req.headers, req.content)
    if isinstance(resp, Response):
        # We assume status codes in this range the request succeeded but was empty (e.g. url is dead)
        if 300 <= resp.status <= 404:
            return
        if decode and not isinstance(resp.data, str):
            data = _handle_response(url, resp, decode=decode, config=traf_config)
            if not isinstance(data, str):
                data = ""
            return Response(resp.url, resp.status, resp.headers, data)
        else:
            return resp


def save_data(k, data):
    if isinstance(data, str):
        LRU_CACHE[k] = data.encode()
    elif isinstance(data, bytes):
        LRU_CACHE[k] = data


def fetch_data(
    url,
    *args,
    delay=0.3,
    backoff=0.3,
    depth=0,
    decode=True,
    asresp=False,
    fromcache=True,
    **kwargs,
):
    if fromcache:
        k = Path(url)
        if k in LRU_CACHE:
            data = LRU_CACHE[k]
        else:
            data = fetch(url, *args, **kwargs, depth=depth, decode=decode)
            save_data(k, data)
    else:
        # with (depth - 1) we ensure that if cached data was `None`
        # the first trial is always performed without proxy
        data = fetch(url, *args, **kwargs, depth=depth - 1, decode=decode)
    if data is None and depth < 4:
        # try an http request 2 times
        if depth == 2:
            url = url.replace("https://", "http://", 1)
        sleep(delay)
        data = fetch_data(
            url,
            *args,
            **kwargs,
            delay=delay + backoff,
            depth=depth + 1,
            decode=decode,
            asresp=asresp,
            fromcache=False,
        )
        save_data(Path(url), data)
    return data
