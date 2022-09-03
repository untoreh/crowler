#!/usr/bin/env python3
#
from ssl import SSLEOFError
from typing import Dict, NamedTuple, Tuple, Callable
import asyncio

import deep_translator
from lingua import Language, LanguageDetectorBuilder
from nltk.tokenize import sent_tokenize
from requests.exceptions import ConnectTimeout, ProxyError

import config as cfg
import log
import proxies_pb as pb
import scheduler as sched


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
    import copy
    import functools

    import requests

    get = copy.deepcopy(requests.get)
    requests.get = functools.partial(get, timeout=10)


class Translator:
    _max_query_len = 5000

    def __init__(self, provider="GoogleTranslator"):

        override_requests_timeout()
        self._tr = getattr(deep_translator, provider)
        self._translate: Dict[Tuple[str, str], Callable] = {}
        self._proxies = {"https": "", "http": ""}
        self._sl = SLang.code
        for (_, code) in TLangs:
            self._translate[(self._sl, code)] = self._tr(source=self._sl, target=code)
        sched.initPool()
        sched.apply(pb.proxy_sync_forever, cfg.PROXIES_FILE)

    def parse_data(self, data: str):
        queries = []
        if len(data) > self._max_query_len:
            tkz = sent_tokenize(data)
            chunk = []
            chunk_len = 0
            for t in tkz:
                token_len = len(t)
                if chunk_len + token_len > self._max_query_len:
                    queries.append("".join(chunk))
                    del chunk[:]
                    chunk_len = 0
                chunk.append(t)
                chunk_len += token_len
            if chunk_len > 0:
                queries.append("".join(chunk))
        else:
            queries.append(data)
        assert all(len(q) < self._max_query_len for q in queries)
        return queries

    @staticmethod
    async def check_queries(q_tasks):
        try:
            while len(q_tasks) > 0:
                todel = []
                for k in q_tasks.keys():
                    if q_tasks[k].done():
                        todel.append(k)
                if len(todel) > 0:
                    for k in todel:
                        del q_tasks[k]
                await asyncio.sleep(1)
        except Exception as e:
            print(e)

    def translate(self, data: str, target: str, source="auto", max_tries=5):
        lp = (source, target)
        if lp not in self._translate:
            self._translate[lp] = self._tr(source=source, target=target)
        tr = self._translate[lp]
        trans = {}
        tries = -1
        query_idx = 0
        queries = self.parse_data(data)
        n_queries = len(queries)
        q_tasks = dict()
        while len(trans) != n_queries:
            tries += 1
            try:
                q = queries[query_idx]

                async def translate_task(qidx: int):
                    tasks: dict[int, asyncio.Task] = {}

                    async def do_trans(i, depth=0):
                        def done(t):
                            v = t.result()
                            if v:
                                return v
                            else:
                                tasks[i] = sched.create_task(do_trans, i, depth + 1)

                        tasks[i].add_done_callback(done)
                        with pb.http_opts(timeout=10, proxy=i):
                            return tr.translate(q)

                    while True:
                        i = len(tasks)
                        # eager translation tasks for the same query (max 4)
                        if i < 5:
                            tasks[len(tasks)] = sched.create_task(do_trans, i)
                        for n in range(0, len(tasks)):
                            t = tasks[n]
                            if t.done():
                                v = t.result()
                                if v:
                                    trans[qidx] = v
                                    for t in tasks.values():
                                        t.cancel()
                                    return
                        await asyncio.sleep(1)

                if query_idx not in trans and query_idx not in q_tasks:
                    # j = sched.apply(translate_task, query_idx)
                    t = sched.create_task(translate_task, query_idx)
                    q_tasks[query_idx] = t

                # Once all queries are asked, wait for q_tasks
                if query_idx + 1 >= len(queries):
                    sched.run(self.check_queries, q_tasks)
                    # reset query_idx, in case some q_tasks failed
                    query_idx = 0
                else:
                    query_idx += 1
            except Exception as e:
                if isinstance(
                    e, (SSLEOFError, ConnectTimeout, ProxyError, ConnectionResetError)
                ):
                    continue
                if tries >= max_tries:
                    import traceback

                    traceback.print_exc()
                    log.warn("Translator: Could not translate, reached max tries.")
                    break
        # return the joined query, correctly ordered by query_idx
        return "".join(trans[k] for k in range(0, len(trans)))


_SLATOR = Translator()


def translate(text: str, to_lang: str, from_lang="auto"):
    return _SLATOR.translate(text, target=to_lang, source=from_lang)
