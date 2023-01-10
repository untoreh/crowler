#!/usr/bin/env python3
from typing import Deque, List, NamedTuple, Tuple, Deque
from multiprocessing.pool import ThreadPool, Pool
from os import cpu_count, getenv
from time import sleep, time
from collections import deque
import sys

# import nest_asyncio
# nest_asyncio.apply()


class PoolInstance(NamedTuple):
    pool: Pool
    jobs: List

    def __len__(self):
        return len(self.jobs)


POOL: None | ThreadPool = None
PROC_POOL: None | Pool = None
POOL_SIZE = int(getenv("PYTHON_WORKERS", cpu_count() or 1))
POOLS: Deque[PoolInstance] = deque()  #  list of (Pool, Jobs)
INITIALIZER = None
INITARGS = []
LAST_CLEANUP = time()
CLEANUP_INTERVAL = 60  # Clean jobs once per minute


def new_pool():
    POOLS.append(PoolInstance(ThreadPool(processes=POOL_SIZE), []))


def new_proc_pool(initializer=INITIALIZER, initargs=INITARGS):
    POOLS.append(
        (
            PoolInstance(
                Pool(processes=POOL_SIZE, initializer=initializer, initargs=initargs),
                [],
            )
        )
    )


to_del = []


def _cleanup_jobs_impl():
    for i in POOLS:
        to_del.clear()
        for (n, j) in enumerate(i.jobs):
            if j.ready():
                to_del.append(n)
        ofs = 0
        for n in to_del:
            del i.jobs[n - ofs]
            ofs += 1
    s = sorted(POOLS, key=lambda p: len(p))
    POOLS.clear()
    POOLS.extend(s)


def cleanup_jobs():
    global LAST_CLEANUP
    if time() - LAST_CLEANUP > CLEANUP_INTERVAL:
        _cleanup_jobs_impl()
        LAST_CLEANUP = time()


def apply(f, *args, **kwargs):
    if len(POOLS) == 0:
        new_pool()
    for i in POOLS:
        if not isinstance(i.pool, ThreadPool):
            continue
        if len(i.jobs) < POOL_SIZE:
            j = i.pool.apply_async(f, args=args, kwds=kwargs)
            i.jobs.append(j)
            cleanup_jobs()
            return j
    # Pools are busy, create a new one
    new_pool()
    return apply(f, *args, **kwargs)


def err(e):
    print(e)
    sys.stdout.flush()


# def apply_procs(f, *args, **kwargs):
#     if len(POOLS) == 0:
#         new_proc_pool()
#     assert isinstance(PROC_POOL, Pool)
#     return PROC_POOL.apply_async(f, args=args, kwds=kwargs, error_callback=err)


# def stop():
#     assert POOL is not None
#     POOL.close()
#     POOL.terminate()
#     POOL.join()


# import asyncio

# loop = asyncio.new_event_loop()


# def apply_coroutine(f, *args, **kwargs):
#     assert isinstance(POOL, ThreadPool)

#     def ff(*argss, **kwargss):
#         return asyncio.run(f(*argss, **kwargss))

#     return POOL.apply_async(ff, args=args, kwds=kwargs)


# def wait_for(f, *args, **kwargs):
#     return loop.run_until_complete(f(*args, **kwargs))


# def get_loop():
#     try:
#         this_loop = asyncio.get_running_loop()
#     except:
#         this_loop = None
#     if not this_loop:
#         this_loop = loop
#     return this_loop


# def create_task(f, *args, **kwargs):
#     return get_loop().create_task(f(*args, **kwargs))


# def run_loop(f, *args, **kwargs):
#     loop = get_loop()
#     if loop.is_running():
#         t = loop.create_task(f(*args, **kwargs))
#         while not t.done():
#             sleep(1)
#         return t.result()
#     else:
#         return get_loop().run_until_complete(f(*args, **kwargs))
#         # return asyncio.run(f(*args, **kwargs))
#     # else:
#     #     return loop.run_until_complete(f(*args, **kwargs))
