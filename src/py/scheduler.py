#!/usr/bin/env python3
from multiprocessing.pool import ThreadPool
import config
# import nest_asyncio
# nest_asyncio.apply()

POOL = None

def initPool():
    global POOL
    if POOL is None:
        POOL = ThreadPool(processes=config.POOL_SIZE)

def apply(f, *args, **kwargs):
    return POOL.apply_async(f, args=args, kwds=kwargs)
