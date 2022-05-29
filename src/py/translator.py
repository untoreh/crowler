#!/usr/bin/env python3
#
from typing import NamedTuple
import deep_translator
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


class Translator:
    def __init__(self, provider="GoogleTranslator"):
        self._tr = getattr(deep_translator, provider)
        self._translate = {}
        self._proxies = {"https": "", "http": ""}
        self._sl = SLang.code
        for (_, code) in TLangs:
            self._translate[(self._sl, code)] = self._tr(
                source=self._sl, target=code
            )
        pb.sync_from_file()

    def translate(self, data: str, target: str):
        lp = (self._sl, target)
        assert lp in self._translate, "(Source Target) language pair not found!"
        trans = ""
        while not trans:
            try:
                prx = pb.get_proxy()
                assert prx is not None
                prx_dict = {}
                prx_dict["https"] = prx
                prx_dict["http"] = prx
                cfg.setproxies(prx)
                tr = self._translate[lp]
                tr.proxies = prx_dict
                trans = tr.translate(data)
            except:
                pass
        return trans
