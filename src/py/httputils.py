#!/usr/bin/env python3
from io import BytesIO
from pathlib import Path
from time import sleep
from typing import Dict, NamedTuple

import numcodecs
import pycurl
import trafilatura.downloads as trad
import zarr as za
from numcodecs import Blosc
from trafilatura.downloads import (
    RawResponse,
    _determine_headers,
    _handle_response,
    fetch_url,
)
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

# pycurl function from trafilatura
def _send_pycurl_request(
    url, no_ssl, config, meth="GET", custom_headers={}, body="", curl=None
):
    """Experimental function using libcurl and pycurl to speed up downloads"""
    # https://github.com/pycurl/pycurl/blob/master/examples/retriever-multi.py

    # init
    headerbytes = BytesIO()
    headers = _determine_headers(config)
    headers.update(custom_headers)
    headerlist = ["Accept-Encoding: gzip, deflate", "Accept: */*"]
    for header, content in headers.items():
        headerlist.append(header + ": " + content)

    # prepare curl request
    # https://curl.haxx.se/libcurl/c/curl_easy_setopt.html
    if curl is None:
        curl = pycurl.Curl()
    curl.setopt(pycurl.CUSTOMREQUEST, meth)
    curl.setopt(pycurl.URL, url.encode("utf-8"))
    # share data
    curl.setopt(pycurl.SHARE, trad.CURL_SHARE)
    curl.setopt(pycurl.HTTPHEADER, headerlist)
    # curl.setopt(pycurl.USERAGENT, '')
    curl.setopt(pycurl.FOLLOWLOCATION, 1)
    curl.setopt(pycurl.MAXREDIRS, trad.MAX_REDIRECTS)
    curl.setopt(pycurl.CONNECTTIMEOUT, trad.TIMEOUT)
    curl.setopt(pycurl.TIMEOUT, trad.TIMEOUT)
    curl.setopt(pycurl.NOSIGNAL, 1)
    if no_ssl is True:
        curl.setopt(pycurl.SSL_VERIFYPEER, 0)
        curl.setopt(pycurl.SSL_VERIFYHOST, 0)
    else:
        curl.setopt(pycurl.CAINFO, trad.certifi.where())
    curl.setopt(pycurl.MAXFILESIZE, config.getint("DEFAULT", "MAX_FILE_SIZE"))
    if len(body):
        curl.setopt(pycurl.POSTFIELDS, body)
    curl.setopt(pycurl.HEADERFUNCTION, headerbytes.write)
    # curl.setopt(pycurl.WRITEDATA, bufferbytes)
    # TCP_FASTOPEN
    # curl.setopt(pycurl.FAILONERROR, 1)
    # curl.setopt(pycurl.ACCEPT_ENCODING, '')

    # send request
    try:
        bufferbytes = curl.perform_rb()
    except pycurl.error as err:
        # retry in case of SSL-related error
        # see https://curl.se/libcurl/c/libcurl-errors.html
        # errmsg = curl.errstr_raw()
        # additional error codes: 80, 90, 96, 98
        if no_ssl is False and err.args[0] in (
            35,
            54,
            58,
            59,
            60,
            64,
            66,
            77,
            82,
            83,
            91,
        ):
            trad.LOGGER.error("retrying after SSL error: %s %s", url, err)
            curl = None
            try:
                curl = pycurl.Curl()
                return _send_pycurl_request(
                    url, True, config, meth, custom_headers, body, curl
                )
            finally:
                if curl is not None:
                    curl.close()
        # traceback.print_exc(file=sys.stderr)
        # sys.stderr.flush()
        return None

    # https://github.com/pycurl/pycurl/blob/master/examples/quickstart/response_headers.py
    respheaders = dict()
    for header_line in (
        headerbytes.getvalue().decode("iso-8859-1").splitlines()
    ):  # re.split(r'\r?\n',
        # This will botch headers that are split on multiple lines...
        if ":" not in header_line:
            continue
        # Break the header line into header name and value.
        name, value = header_line.split(":", 1)
        # Now we can actually record the header name and value.
        respheaders[name.strip()] = value.strip()  # name.strip().lower() ## TODO: check
    # status
    respcode = curl.getinfo(pycurl.RESPONSE_CODE)
    # url
    effective_url = curl.getinfo(pycurl.EFFECTIVE_URL)
    # additional info
    # ip_info = curl.getinfo(curl.PRIMARY_IP)

    # return RawResponse(bufferbytes, respcode, effective_url)
    return Response(effective_url, respcode, respheaders, bufferbytes)


def send_request(url, no_ssl, config, meth="GET", headers={}, body="", curl=None):
    try:
        if curl is None:
            curl = pycurl.Curl()
        try:
            res = _send_pycurl_request(url, no_ssl, config, meth, headers, body, curl)
        except Exception as e:
            print(e)
        return res
    finally:
        if curl is not None:
            curl.close()


def fetch(url, depth, *args, meth="GET", headers={}, body="", decode=True, **kwargs):
    resp = ""
    with pb.http_opts(proxy=depth):
        # use ssl only when without proxy
        resp = send_request(
            url,
            no_ssl=(depth > 0),
            config=traf_config,
            meth=meth,
            headers=headers,
            body=body,
        )
    if isinstance(resp, Response):
        # We assume status codes in this range the request succeeded but was empty (e.g. url is dead)
        if 300 <= resp.status <= 404:
            return
        if decode:
            data = _handle_response(url, resp, decode=decode, config=traf_config)
            if not isinstance(data, str):
                data = ""
            return Response(resp.url, resp.status, resp.headers, data)
        else:
            return resp


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
        if url in LRU_CACHE:
            data = LRU_CACHE[Path(url)]
        else:
            data = fetch(url, *args, **kwargs, depth=-1, decode=decode)
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
        try:
            LRU_CACHE[Path(url)] = data
        except:
            pass
    return data
