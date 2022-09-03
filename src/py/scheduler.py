#!/usr/bin/env python3
from multiprocessing.pool import ThreadPool
import config
from time import sleep

# import nest_asyncio
# nest_asyncio.apply()

POOL: None | ThreadPool = None


def initPool(restart=False):
    global POOL
    if POOL is None or restart:
        if POOL is not None:
            POOL.close()
            POOL.terminate()
            POOL.join()
        POOL = ThreadPool(processes=config.POOL_SIZE)


def apply(f, *args, **kwargs):
    assert isinstance(POOL, ThreadPool)
    return POOL.apply_async(f, args=args, kwds=kwargs)


def stop():
    assert POOL is not None
    POOL.close()
    POOL.terminate()
    POOL.join()


import asyncio

loop = asyncio.new_event_loop()

def wait_for(f, *args, **kwargs):
    return loop.run_until_complete(f(*args, **kwargs))

def get_loop():
    try:
        this_loop = asyncio.get_running_loop()
    except:
        this_loop = None
    if not this_loop:
        this_loop = loop
    return this_loop

def create_task(f, *args, **kwargs):
    return get_loop().create_task(f(*args, **kwargs))

def run(f, *args, **kwargs):
    loop = get_loop()
    if loop.is_running():
        return asyncio.run(f(*args, **kwargs))
    else:
        return loop.run_until_complete(f(*args, **kwargs))
