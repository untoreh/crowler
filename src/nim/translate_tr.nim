import
    cfg,
    xmltree,
    nre,
    strutils,
    strformat,
    tables,
    nimpy,
    sugar,
    sequtils,
    hashes,
    std/sharedtables

import
    quirks,
    cfg,
    utils,
    types,
    translate_types,
    translate_srv,
    translate_db,
    locks

type splitSent = object
    sents: seq[string]
    size: int

proc add(ss: ptr splitSent, s: string) =
    ss.sents.add(s)
    ss.size += s.len

proc clear(ss: ptr splitSent) =
    ss.sents.setLen(0)
    ss.size = 0

proc len(ss: ptr splitSent): int = ss.size

var
    sentsIn: ptr splitSent
    transOut: ptr seq[string]
    splitCache: ptr Table[string, seq[string]]
    scLock: Lock
    elSents {.threadvar.}: seq[string]

sentsIn = create(splitSent)
transOut = create(seq[string])
splitCache = create(Table[string, seq[string]])
initLock(scLock)

proc checkBatchedTranslation(sents: seq[string], query = "", tr: auto) =
    if len(tr) != len(sents):
        var err = "query: "
        err.add query
        for t in tr:
            err.add "tr: "
            err.add t
        err.add "mismatching batched translation query result: "
        err.add fmt"{tr.len} - {sents.len}"
        raise newException(ValueError, err)

proc doQuery[T](q: T, sents: seq[string]): seq[string] =
    ## Iterate over all the separators pair until a bijective mapping is found
    var
        tr: seq[string]
        itr = 1
        query = ""

    for (sep, splitsep) in q.glues:
        query = join(sents, sep)
        assert query.len < q.bufsize, fmt"mmh: {sents.len}, {query.len}"
        debug "query: calling translation function, bucket: {q.bucket.len}, query: {query.len}"
        let res = q.call(query, q.pair)
        debug "query: response size: {res.len}"
        let tr = res.split(splitsep)
        debug "query: split translations"
        if len(tr) == len(sents):
            debug "query: translation successful."
            return tr
        debug "query: translation failed, trying new glue ({itr})"
        itr += 1
    checkBatchedTranslation(sents, query, tr)

proc doTrans(q: auto) =
    let tr = doQuery(q, collect(for s in sentsIn.sents: s))
    debug "doTrans: appending trans"
    transOut[].add(tr)
    debug "doTrans: clearing sentences"
    sentsIn.clear()

proc setEl(q, el: auto, t: string) =
    # debug "slations: saving translation"
    discard slations[].hasKeyOrPut(hash((q.pair, el.getText)).int64, t)
    # debug "slations: setting element"
    el.setText(t)

proc reachedBufSize(s: auto, sz: int, bufsize: int): bool = (len(s) * gluePadding + sz) > bufsize
proc reachedBufSize[T](s: seq, q: T): bool = reachedBufSize(s, q.sz, q.bufsize)
proc reachedBufSize[T](s: int, q: T): bool = reachedBufSize(q.bucket, s + q.sz, q.bufsize)

proc elUpdate(q, el, srv: auto) =
    # TODO: sentence splitting should be memoized
    debug "elupdate: splitting sentences"
    elSents.setLen(0)
    withLock(scLock):
        let txt = el.getText
        if not (txt in splitCache[]):
            splitCache[][txt] = splitSentences(txt)
        elSents.add splitCache[][txt]
    debug "elupdate: translating"
    for s in elSents:
        if reachedBufSize(sentsIn.sents, sentsIn.len + s.len, q.bufsize):
            doTrans(q)
        sentsIn.add(s)
    if sentsIn.len > 0:
        doTrans(q)
    debug "elupdate: setting translation"
    setEl(q, el, transOut[].join)
    transOut[].setLen(0)
    debug "elupdate: end"


proc elementsUpdate[T](q: var T) =
    ## Update all the elements in the queue
    debug "eleupdate: performing batch translation"
    let tr = doQuery(q, collect(for el in q.bucket: el.getText))
    debug "eleupdate: setting elements"
    for (el, t) in zip(q.bucket, tr):
        # debug "el: {el.tag}, {t}"
        setEl(q, el, t)
    debug "eleupdate: cleaning up queue"
    q.bucket.setLen(0)
    q.sz = 0

proc translate*[Q, T](q: var Q, el: T, srv: auto) =
    let (success, length) = setFromDB(q.pair, el)
    if not success:
        if length > q.bufsize:
            debug "Translating element singularly since it is big"
            elUpdate(q, el, srv)
            debug "Saving translations! {slations[].len}"
            saveToDb()
        else:
            if reachedBufSize(length, q):
                elementsUpdate(q)
                saveToDB()
            q.bucket.add(el)
            q.sz += length

proc translate*[Q, T](q: T, el: T, srv: auto, finish: bool) =
    if finish:
        let (success, _) = setFromDB(q.pair, el)
        if not success:
            let t = q.translate(el.getText)
            el.setText(t)

proc translate*[Q](q: var Q, srv: auto, finish: bool) =
    if finish and q.sz > 0:
        elementsUpdate(q)
        saveToDB()

# when isMainModule:
#     let
#         pair = (src: "en", trg: "it")
#         slator = initTranslator()

#     var q = getTfun(pair, slator).initQueue(pair, slator)
#     echo q.translate("Hello")
