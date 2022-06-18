#!/usr/bin/env python3
from multiprocessing.pool import ThreadPool
import config
# import nest_asyncio
# nest_asyncio.apply()

POOL = None

def initPool(restart=False):
    global POOL
    if POOL is None or restart:
        if POOL is not None:
            POOL.close()
            POOL.terminate()
            POOL.join()
        POOL = ThreadPool(processes=config.POOL_SIZE)

def apply(f, *args, **kwargs):
    return POOL.apply_async(f, args=args, kwds=kwargs)
