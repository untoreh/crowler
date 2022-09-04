import
    xmltree,
    nre,
    strutils,
    strformat,
    tables,
    nimpy,
    sugar,
    sequtils,
    hashes,
    std/[sharedtables],
    chronos,
    karax/vdom

import
    quirks,
    cfg,
    utils,
    types,
    locktpl,
    translate_types,
    translate_srv,
    translate_db,
    locks

type splitSent = ref object
    sents: seq[string]
    size: int

proc add(ss: splitSent, s: string) =
    ss.sents.add(s)
    ss.size += s.len

proc clear(ss: splitSent) =
    ss.sents.setLen(0)
    ss.size = 0

proc len(ss: splitSent): int = ss.size

type JobsQueueTypeXml = seq[(seq[XmlNode], QueueXml, seq[seq[string]])]
type JobsQueueTypeVNode = seq[(seq[VNode], QueueDom, seq[seq[string]])]

var
    jobsQueueX {.threadvar.}: JobsQueueTypeXml
    jobsQueueV {.threadvar.}: JobsQueueTypeVNode

proc addJob(els: seq[XmlNode], q: QueueXml, batches: seq[seq[string]]) = jobsQueueX.add (els, q, batches)
proc addJob(els: seq[VNode], q: QueueDom, batches: seq[seq[string]]) = jobsQueueV.add (els, q, batches)

let splitCache = initLockLRUCache[string, seq[string]](1000)

proc checkBatchedTranslation(sents: seq[string], query = "", tr: auto) =
    if len(tr) != len(sents):
        var err = "query: "
        err.add query
        for t in tr:
            err.add "tr: "
            err.add t
        err.add "\nmismatching batched translation query result: "
        err.add fmt"{tr.len} - {sents.len}"
        raise newException(ValueError, err)

proc doQuery(q: auto, sents: seq[string]): Future[seq[string]] {.async.} =
    ## Iterate over all the separators pair until a bijective mapping is found
    var
        itr = 1
        query = ""

    for (sep, splitsep) in q.glues:
        query = join(sents, sep)
        assert query.len < q.bufsize, fmt"mmh: {sents.len}, {query.len}"
        # debug "query: calling translation function, bucket: {q.bucket.len()}, query: {query.len}"
        let res = await callTranslator(query, q.pair)
        # let res = q.doCall(query)
        logall "query: response size: {res.len}"
        result = res.split(splitsep)
        logall "query: split translations"
        if len(result) == len(sents):
            debug "query: translation successful."
            return
        debug "query: translation failed ({len(result)}, {len(sents)}), trying new glue ({itr})"
        itr += 1
    checkBatchedTranslation(sents, query, result)

proc toSeq(sentsIn: splitSent): seq[string] =
    result = collect(for s in sentsIn.sents: s)
    # doQuery(q, collect(for s in sentsIn.sents: s))
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
    var
        elSents: seq[string]
        transOut: seq[string]
        sentsIn = splitSent()
        batches: seq[seq[string]]
    sentsIn.size = 0
    let txt = el.getText
    elSents.add if txt in splitCache:
                    splitCache[txt]
                else: splitSentences(txt)
    # debug "elupdate: translating"
    for s in elSents:
        if reachedBufSize(sentsIn.sents, sentsIn.len + s.len, q.bufsize):
            batches.add sentsIn.toSeq
        sentsIn.add(s)
    if sentsIn.len > 0:
        batches.add sentsIn.toSeq
    debug "pushing job to queue"
    addJob(@[el], q, batches)
    debug "elupdate: end"

proc checkJobs(q: QueueXml) = doassert jobsQueueX[^1][0].len > 0
proc checkJobs(q: QueueDom) = doassert jobsQueueV[^1][0].len > 0

proc push[T](q: var T) =
    ## Push the translation job for all elements in the queue
    var batches: seq[seq[string]]
    batches.add collect(for el in q.bucket: el.getText)
    addJob(q.bucket, q, batches)
    q.bucket.setLen(0)
    q.sz = 0
    checkJobs(q)


proc elementsUpdate[T](q: var T) =
    ## Update all the elements in the queue
    debug "eleupdate: performing batch translation"
    # let tr = doQuery(q, )
    debug "eleupdate: setting elements"
    for (el, t) in zip(q.bucket, tr):
        # debug "el: {el.tag}, {t}"
        setEl(q, el, t)
    debug "eleupdate: cleaning up queue"
    # q.bucket.setLen(0)
    # q.sz = 0

proc doQueryAll(els: auto, q: QueueXml | QueueDom, batches: seq[seq[string]]): Future[void] {.async.} =
  # We might have multiple batches when translating a single element
  var tr: seq[string]
  if len(els) == 1:
    for batch in batches:
      tr.add await doQuery(q, batch)
    setEl(q, els[0], tr.join())
    saveToDB()
  else:
    doassert len(batches) == 1
    tr.add await doQuery(q, batches[0])
    for (el, t) in zip(els, tr):
      setEl(q, el, t)
    saveToDB()

proc queueTrans(): seq[Future[void]]  =
    var jobs: seq[Future[void]]
    for (els, q, batches) in jobsQueueX:
      jobs.add doQueryAll(els, q, batches)
    for (els, q, batches) in jobsQueueV:
      jobs.add doQueryAll(els, q, batches)
    debug "translate: waiting for {len(jobs)} jobs."
    return jobs

proc doTrans*() {.async.} =
    let jobs = queueTrans()
    for j in jobs:
        await j
    saveToDB(force=true)

proc translate*[T](q: ptr[QueueXml | QueueDom], el: T, srv: service) =
    if q.isnil:
      warn "translate: queue can't be nil"
      return
    let (success, length) = setFromDB(q[].pair, el)
    if not success:
        if length > q[].bufsize:
            debug "Translating element singularly since it is big"
            elUpdate(q[], el, srv)
        else:
            if reachedBufSize(length, q[]):
                q[].push()
            q[].bucket.add(el)
            q[].sz += length

proc translate*[T](q: ptr[QueueXml | QueueDom], el: T, srv: service, finish: bool): Future[bool] {.async.} =
    if finish:
        if q.isnil:
            return true
        let (success, _) = setFromDB(q[].pair, el)
        if not success:
            addJob(@[el], q[], el.getText)
            debug "translate: waiting for pair: {q[].pair}"
            await doTrans()
    return true

proc translate*(q: ptr[QueueXml | QueueDom], srv: service, finish: bool): Future[bool] {.async.} =
    if finish and q[].sz > 0:
        q[].push()
        await doTrans()
        saveToDB(force=true)
    return true
