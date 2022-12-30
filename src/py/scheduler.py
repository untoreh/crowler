#!/usr/bin/env python3
from multiprocessing.pool import ThreadPool, Pool
from os import cpu_count, getenv
from time import sleep
import sys

# import nest_asyncio
# nest_asyncio.apply()

POOL: None | ThreadPool = None
PROC_POOL: None | Pool = None
POOL_SIZE = int(getenv("PYTHON_WORKERS", cpu_count() or 1))

def initPool(restart=False, thr=True, procs=False, initializer=None, initargs=[]):
    global POOL, PROC_POOL
    if thr and POOL is None or restart:
        if POOL is not None:
            POOL.close()
            POOL.terminate()
        POOL = ThreadPool(processes=POOL_SIZE)
    if procs:
        if PROC_POOL is None or restart:
            if PROC_POOL is not None:
                PROC_POOL.close()
                PROC_POOL.terminate()
            PROC_POOL = Pool(
                processes=POOL_SIZE, initializer=initializer, initargs=initargs
            )


def apply(f, *args, **kwargs):
    assert isinstance(POOL, ThreadPool)
    return POOL.apply_async(f, args=args, kwds=kwargs)


def err(e):
    print(e)
    sys.stdout.flush()

def apply_procs(f, *args, **kwargs):
    assert isinstance(PROC_POOL, Pool)
    return PROC_POOL.apply_async(f, args=args, kwds=kwargs, error_callback=err)


def stop():
    assert POOL is not None
    POOL.close()
    POOL.terminate()
    POOL.join()


import asyncio

loop = asyncio.new_event_loop()


def apply_coroutine(f, *args, **kwargs):
    assert isinstance(POOL, ThreadPool)

    def ff(*argss, **kwargss):
        return asyncio.run(f(*argss, **kwargss))

    return POOL.apply_async(ff, args=args, kwds=kwargs)


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


def run_loop(f, *args, **kwargs):
    loop = get_loop()
    if loop.is_running():
        t = loop.create_task(f(*args, **kwargs))
        while not t.done():
            sleep(1)
        return t.result()
    else:
        return get_loop().run_until_complete(f(*args, **kwargs))
        # return asyncio.run(f(*args, **kwargs))
    # else:
    #     return loop.run_until_complete(f(*args, **kwargs))
