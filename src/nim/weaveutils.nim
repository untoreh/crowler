import weave, weave/[runtime, contexts]
export weave

proc isWeaveOff*(): bool {.inline.} = globalCtx.numWorkers == 0 or workerContext.signaledTerminate

template withWeave*(doexit = false, args: untyped) =
    # os.putenv("WEAVE_NUM_THREADS", "2")
    if isWeaveOff():
        init(Weave, initThread)
        initThread()
    args
    if doexit:
        exit(Weave, exitThread)
        exitThread()
