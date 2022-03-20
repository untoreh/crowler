import cfg,
       xmltree,
       nre,
       strutils,
       tables,
       nimpy,
       sugar,
       sequtils

import
    cfg,
    utils,
    translate_types,
    translate_srv,
    translate_db,
    quirks

var
    sentsIn: seq[string] = @[]
    transOut: seq[string] = @[]

proc checkBatchedTranslation(q, query, trans: auto) =
    if len(trans) != len(q.bucket):
        echo query
        for t in trans:
            echo t
        raise newException(ValueError, "mismatching batched translation query result: " & "{trans.len} - {q.bucket.len}")


proc doTrans(q: auto) =
    let
        query = join(sentsIn, q.glue)
        trans = q.translate(query).split(q.splitGlue)

    checkBatchedTranslation(q, query, trans)
    transOut.add(trans)
    sentsIn.clear

proc setEl(q, el, trans: auto) =
    trans[q.pair][getText(el)] = trans
    setText(el, trans)


proc elUpdate(q, el, srv: auto) =
    var length = 0
    let sents: lent = splitSentences(getText(el))
    for s in sents:
        length += s.len
        if length > q.bufsize:
            assert len(sentsIn) > 0
            doTrans(q)
        doTrans(q)
        setEl(q, el, transOut.join)
        transOut.clear



proc elementsUpdate(q: auto) =
    ##
    let query = join(collect(for el in q.bucket: getText(el)), q.glue)
    debug "querying translation function, bucket: {q.bucket.len}, query: {query.len}"
    let trans = q.translate(query).split(q.splitGlue)
    checkBatchedTranslation(q, query, trans)
    for (el, t) in zip(q.bucket, trans):
        setEl(q, el, t)
    clear(q.bucket)
    q.sz = 0

proc translate*(q: Queue, el: XmlNode, srv: auto, finish=false) =
    let (success, length) = setFromDB(q.pair, el)
    if length > q.bufsize:
        elUpdate(q, el, srv)
    else:
        if q.size + length > q.bufsize:
            elementsUpdate(q)
            # saveToDB()
        q.bucket.add(el)
        q.size += length

when isMainModule:
    let
        pair = (src: "en", trg: "it")
        slator = initTranslator()

    var q = getTfun(pair, slator).initQueue(pair, slator)
