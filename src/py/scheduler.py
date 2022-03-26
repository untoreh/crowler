#!/usr/bin/env python3
from multiprocessing.pool import ThreadPool
import config


def initPool():
    global POOL
    POOL = ThreadPool(processes=config.POOL_SIZE)

def apply(f, *args, **kwargs):
    return POOL.apply_async(f, args=args, kwds=kwargs)
