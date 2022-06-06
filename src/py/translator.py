#!/usr/bin/env python3
#
from typing import NamedTuple
import deep_translator
from lingua import Language, LanguageDetectorBuilder

import config as cfg
import proxies_pb as pb


class Lang(NamedTuple):
    name: str
    code: str


class LangPair(NamedTuple):
    src: str
    trg: str


SLang = Lang("English", "en")
TLangs = [
    Lang(*l)
    for l in [  ## TLangs are all the target languages, the Source language is not included
        ("German", "de"),
        ("Italian", "it"),
        ("Mandarin Chinese", "zh-CN"),
        ("Spanish", "es"),
        ("Hindi", "hi"),
        ("Arabic", "ar"),
        ("Portuguese", "pt"),
        ("Bengali", "bn"),
        ("Russian", "ru"),
        ("Japanese", "ja"),
        ("Punjabi", "pa"),
        ("Javanese", "jw"),
        ("Vietnamese", "vi"),
        ("French", "fr"),
        ("Urdu", "ur"),
        ("Turkish", "tr"),
        ("Polish", "pl"),
        ("Ukranian", "uk"),
        ("Dutch", "nl"),
        ("Greek", "el"),
        ("Swedish", "sv"),
        ("Zulu", "zu"),
        ("Romanian", "ro"),
        ("Malay", "ms"),
        ("Korean", "ko"),
        ("Thai", "th"),
        ("Filipino", "tl"),
    ]
]
TLangs_dict = {code: name for code, name in TLangs}
TLangs_dict["zh"] = "Mandarin Chinese"


def init_detector():
    global DETECTOR
    sl = SLang.name.upper()
    langs = [getattr(Language, sl)]
    for (name, code) in TLangs:
        if code == "zh-CN":
            name = "CHINESE"
        try:
            langs.append(getattr(Language, name.upper()))
        except AttributeError:
            pass
    DETECTOR = (
        LanguageDetectorBuilder.from_languages(*langs)
        .with_minimum_relative_distance(0.05)
        .build()
    )


init_detector()


def detect(s: str):
    l = DETECTOR.detect_language_of(s)
    if l is None:
        return SLang.code
    code = l.iso_code_639_1.name.lower()
    return code if code != "zh" else "zh-CN"


# def try_wrapper(fn, n: int, def_val=""):
#     def wrapped_fn(*args, tries=1, e=None):
#         if tries < n:
#             try:
#                 return fn(*args)
#             except Exception as ex:
#                 sleep(tries)
#                 return wrapped_fn(*args, tries=tries + 1, e=ex)
#         else:
#             print("wrapped function reached max tries, last exception was: ", e)
#             return def_val

#     return wrapped_fn


def override_requests_timeout():
    import requests, copy, functools

    get = copy.deepcopy(requests.get)
    requests.get = functools.partial(get, timeout=10)


class Translator:
    def __init__(self, provider="GoogleTranslator"):
        override_requests_timeout()
        self._tr = getattr(deep_translator, provider)
        self._translate = {}
        self._proxies = {"https": "", "http": ""}
        self._sl = SLang.code
        for (_, code) in TLangs:
            self._translate[(self._sl, code)] = self._tr(source=self._sl, target=code)
        pb.sync_from_file()

    def translate(self, data: str, target: str, source=SLang.code):
        lp = (source, target)
        if lp not in self._translate:
            self._translate[lp] = self._tr(source=source, target=target)
        tr = self._translate[lp]
        prx_dict = {}
        cfg.setproxies(None)
        cfg.set_socket_timeout(5)
        trans = ""
        while not trans:
            try:
                prx = pb.get_proxy()
                if prx is None:
                    import log

                    log.logger.warn(
                        "Couldn't get a proxy, using STATIC PROXY endpoint."
                    )
                    prx = cfg.STATIC_PROXY_EP
                prx_dict["https"] = prx
                prx_dict["http"] = prx
                tr.proxies = prx_dict
                trans = tr.translate(data)
            except:
                pass
        return trans


_SLATOR = Translator()

def translate(text: str, to_lang: str, from_lang: str):
    return _SLATOR.translate(text, target=to_lang, source=from_lang)
