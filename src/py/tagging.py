#!/usr/bin/env python3
import config as cfg
from pyate import combo_basic
import utils as ut
import spacy
import pytextrank as _
import phrasemachine
from rake_nltk import Rake
import nltk
from textacy import similarity
from re import sub

nltk.download("stopwords")
rk = Rake()
rk.max_length = cfg.TAGS_MAX_LEN


def ate(text, n=3):
    tags = combo_basic(text)
    tags.sort_values(inplace=True)
    return tags[-n:].index.tolist()


def textrank(text, n=3, rank_n=100, rank_distance=0.05):
    nlp = spacy.load(cfg.SPACY_MODEL)
    nlp.add_pipe("textrank")
    doc = nlp(text)
    phrases = doc._.phrases
    sr = sorted(phrases, key=lambda p: p.rank, reverse=False)
    tags = [sr[-1].text]
    last_rank = sr[-1].rank - rank_distance
    for s in sr[-rank_n:-1]:
        if s.rank < last_rank:
            tags.append(s.text)
            last_rank = s.rank - rank_distance
    return tags[-n:]


def phrasemac(text, n=3, max_len=cfg.TAGS_MAX_LEN):
    phr = phrasemachine.get_phrases(text)
    # phrases = sorted(list(phr["counts"].items()), key=lambda x: x[1])
    phrases = sorted(list(phr["counts"].items()), key=lambda x: x[1])
    phr_set = set(phrases[-n:])
    for (p, _) in phrases[-n:]:
        if len(p.split()) > max_len:
            phr_set.remove(p)
            continue
        for (pp, _) in phrases:
            if p != pp and p in pp and p in phr_set:
                phr_set.remove(p)
    return [x[0] for x in phr_set]


def rake(text, n=3, n_filter=100, clean=True):
    rk.extract_keywords_from_text(text)
    kws = rk.get_ranked_phrases()
    tags = set(ut.dedup(kws[:n_filter])[:n])
    tags = sim_filter(tags)
    return clean_tags(tags) if clean else tags


def sim_filter(tags, sim_threshold=0.9):
    final = []
    for t in tags:
        sim = False
        for f in final:
            if similarity.levenshtein(t, f) > sim_threshold:
                sim = True
        if not sim:
            final.append(t)
    return final


def clean_tags(tags):
    cleaned_tags = []
    for t in tags:
        # Replace bad hyphens
        t = sub("[^a-zA-Z]-[^a-zA-Z]?", "", t)
        t = sub("[^a-zA-Z]?-[^a-zA-Z]", "", t)
        # Remove non chars
        t = sub(r"[^a-zA-Z\-\s]", "", t)
        if len(t.strip(" -")) > 3:
            cleaned_tags.append(t)
    return cleaned_tags


def all(text):
    res = dict()
    res["ate"] = ate(text)
    res["tr"] = textrank(text)
    res["phr"] = phrasemac(text)
    res["rk"] = rake(text)
    tags = []
    for v in res.values():
        tags.extend(v)
    return ut.dedup(tags)
