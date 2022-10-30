import chronos, taskpools, std/[uri, httpclient, os]

import utils, httptypes
const DEFAULT_TIMEOUT = 4.seconds
const N_THREADS = 128

var handlerThread: Thread[void]

proc getClient(redir = true, timeout: int = 0, trial: int = 0): HttpClient =
  let prx =
    block:
      let sel = selectProxy(trial)
      if sel == "": nil
      else: newProxy(sel)
  newHttpClient(
    maxRedirects = (if redir: 5 else: 0),
    proxy = prx,
    sslContext = newContext(verifyMode = CVerifyNone),
    timeout = timeout
  )

template doTry(trial: int) =
  var cl: HttpClient
  try:
    cl = getClient(rq.redir, timeout.milliseconds.int, trial)
    let resp = cl.request(rq.url, httpMethod = rq.meth,
                          headers = rq.headers, body = rq.body)
    r.code = resp.code
    checkNil(resp.headers)
    r.headers = resp.headers
    if r.code == Http200:
      r.body = resp.body
  except ProtocolError as e: # timeout?
    warn "protocol error: is proxy running? {selectProxy(trial)}"
    sleep(1000)
  except Exception:
    logexc()
  finally:
    if not cl.isnil:
      cl.close()

proc doReq(rq: ptr Request, timeout = DEFAULT_TIMEOUT): bool =
  checkNil(rq.response)
  let r = rq.response
  var trial = 0
  while trial < rq.retries:
    doTry(trial)
    if r.body.len > 0:
      break
    trial.inc
  # the response
  waitFor httpOut.put(rq, true)
  return true

proc handler() =
  var rq: ptr Request
  let tp = Taskpool.new(num_threads = N_THREADS)
  while true:
    try:
      warn "http: starting httpHandler..."
      while true:
        rq = waitFor httpIn.pop
        checkNil(rq)
        discard tp.spawn doReq(move rq)
    except:
      logexc()
      warn "http: httpHandler crashed."

proc initHttp*() =
  httptypes.initHttp()
  createThread(handlerThread, handler)

when isMainModule:
  initHttp()
