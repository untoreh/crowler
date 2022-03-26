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
    hashes

import
    quirks,
    cfg,
    utils,
    types,
    translate_types,
    translate_srv,
    translate_db

type splitSent = object
    sents: seq[string]
    size: int

proc add(ss: ptr splitSent, s: string) =
    ss[].sents.add(s)
    ss[].size += s.len

proc clear(ss: ptr splitSent) =
    ss[].sents.setLen(0)
    ss[].size = 0

proc len(ss: ptr splitSent): int = ss[].size

var
    sentsIn: ptr splitSent
    transOut: ptr seq[string]
sentsIn = new(splitSent)[].addr

proc checkBatchedTranslation(sents: seq[string], query="", tr: auto) =
    if len(tr) != len(sents):
        echo "query: ", query
        for t in tr:
            echo "tr: ", t
        raise newException(ValueError, "mismatching batched translation query result: " &
                fmt"{tr.len} - {sents.len}")

proc doQuery(q: Queue, sents: seq[string]): seq[string] =
    ## Iterate over all the separators pair until a bijective mapping is found
    var
        tr: seq[string]
        itr = 1
        query = ""

    for (sep, splitsep) in q.glues:
        query = join(sents, sep)
        debug "query: calling translation function, bucket: {q.bucket.len}, query: {query.len}"
        let res = q.call(query)
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
    slations[hash((q.pair, el.getText)).int] = t
    # debug "slations: setting element"
    el.setText(t)

proc elUpdate(q, el, srv: auto) =
    # TODO: sentence splitting should be memoized
    debug "elupdate: splitting sentences"
    let sents = splitSentences(el.getText)
    debug "elupdate: translating"
    for s in sents:
        if sentsIn.len > q.bufsize:
            doTrans(q)
        sentsIn.add(s)
    if sentsIn.len > 0:
        doTrans(q)
    debug "elupdate: setting translation"
    setEl(q, el, transOut[].join)
    transOut[].setLen(0)
    debug "elupdate: end"


proc elementsUpdate(q: var auto) =
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

proc translate*(q: var Queue, el: XmlNode, srv: auto) =
    let (success, length) = setFromDB(q.pair, el)
    if not success:
        if length > q.bufsize:
            debug "Translating element singularly since it is big"
            elUpdate(q, el, srv)
            debug "Saving translations! {slations.len}"
            saveToDb(force=true)
        else:
            if q.sz + length > q.bufsize:
                elementsUpdate(q)
                saveToDB()
            q.bucket.add(el)
            q.sz += length

proc translate*(q: Queue, el: XmlNode, srv: auto, finish: bool) =
    if finish:
        let (success, _) = setFromDB(q.pair, el)
        if not success:
            let t = q.translate(el.getText)
            el.setText(t)

proc translate*(q: var Queue, srv: auto, finish: bool) =
    if finish and q.sz > 0:
        elementsUpdate(q)
        saveToDB()

# when isMainModule:
#     let
#         pair = (src: "en", trg: "it")
#         slator = initTranslator()

#     var q = getTfun(pair, slator).initQueue(pair, slator)
#     echo q.translate("Hello")
