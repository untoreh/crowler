#!/usr/bin/env python3
#
from typing import Dict, NamedTuple, Tuple, Callable
from multiprocessing.pool import AsyncResult
from time import sleep

import deep_translator
from lingua import Language, LanguageDetectorBuilder
from nltk.tokenize import sent_tokenize

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


class Translator:
    _max_query_len = 5000
    _inflight = 0

    def __init__(self, provider="GoogleTranslator"):

        self._tr = getattr(deep_translator, provider)
        self._translate: Dict[Tuple[str, str], Callable] = {}
        self._proxies = {"https": "", "http": ""}
        self._sl = SLang.code
        for (_, code) in TLangs:
            self._translate[(self._sl, code)] = self._tr(source=self._sl, target=code)
        sched.initPool(procs=False)
        sched.apply(pb.proxy_sync_forever, cfg.PROXIES_FILE)
        log.info("translator: initialized.")

    @staticmethod
    def parse_data(data: str):
        queries = []
        if len(data) > Translator._max_query_len:
            tkz = sent_tokenize(data)
            chunk = []
            chunk_len = 0
            for t in tkz:
                token_len = len(t)
                if chunk_len + token_len > Translator._max_query_len:
                    queries.append("".join(chunk))
                    del chunk[:]
                    chunk_len = 0
                chunk.append(t)
                chunk_len += token_len
            if chunk_len > 0:
                queries.append("".join(chunk))
        else:
            queries.append(data)
        assert all(len(q) < Translator._max_query_len for q in queries)
        return queries

    @staticmethod
    def check_queries(q_tasks: dict[int, AsyncResult], trans):
        try:
            while len(q_tasks) > 0:
                todel = []
                for k in q_tasks.keys():
                    t = q_tasks[k]
                    if t.ready():
                        if t.successful():
                            trans[k] = t.get()
                        todel.append(k)
                if len(todel) > 0:
                    for k in todel:
                        del q_tasks[k]
                sleep(1)
        except Exception as e:
            print(e)

    def translate(self, data: str, target: str, source="auto", max_tries=5):
        if self._inflight % 50 == 0:
            log.info("translator: current inflight count: %s", self._inflight)
        lp = (source, target)
        if lp not in self._translate:
            self._translate[lp] = self._tr(source=source, target=target)
        tr = self._translate[lp]
        trans = {}
        tries = -1
        query_idx = 0
        queries = self.parse_data(data)
        n_queries = len(queries)
        q_tasks: Dict[int, AsyncResult] = dict()
        while len(trans) != n_queries:
            if n_queries == 1:
                q = queries[0]

                def do_trans_single(depth=1):
                    try:
                        if depth == 1:
                            self._inflight += 1
                        with pb.http_opts(proxy=1):
                            return tr.translate(q)
                    except:
                        return do_trans_single(depth + 1)
                    finally:
                        if depth == 1:
                            self._inflight -= 1

                trans[query_idx] = do_trans_single()
                break
            try:
                q = queries[query_idx]

                def do_trans(q, depth=1):
                    try:
                        if depth == 1:
                            self._inflight += 1
                        with pb.http_opts(proxy=1):
                            return tr.translate(q)
                    except:
                        return do_trans(q, depth=depth + 1)
                    finally:
                        if depth == 1:
                            self._inflight -= 1


                if query_idx not in trans and query_idx not in q_tasks:
                    q_tasks[query_idx] = sched.apply(do_trans, q)
                    assert query_idx in q_tasks
                if query_idx + 1 >= len(queries):
                    self.check_queries(q_tasks, trans)
                    query_idx = 0
                else:
                    query_idx += 1
            except:
                tries += 1
                if tries >= max_tries:
                    import traceback

                    traceback.print_exc()
                    log.warn("Translator: Could not translate, reached max tries.")
                    break
        # return the joined query, correctly ordered by query_idx
        return "".join(trans[k] for k in range(0, len(trans)))


_SLATOR = Translator()


def translate(text: str, to_lang: str, from_lang="auto"):
    global _SLATOR
    if _SLATOR is None:
        _SLATOR = Translator()
        sched.initPool(procs=False)
    return _SLATOR.translate(text, target=to_lang, source=from_lang)
