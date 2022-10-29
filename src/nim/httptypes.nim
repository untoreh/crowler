import std/[uri, httpcore, monotimes, hashes]
export monotimes
import locktplutils
type
  TimeoutError* = object of CatchableError
  RequestError* = object of CatchableError

type
  Decode* = enum no, yes
  Response* = object
    code*: HttpCode
    headers*: HttpHeaders
    body*: string
    size*: int
  ResponseRef* = ref Response
  Request* = object
    id*: MonoTime
    url*: Uri
    meth*: HttpMethod
    headers*: HttpHeaders
    body*: string
    redir*: bool
    decode*: Decode
    proxied*: bool
    retries*: int
    response*: ptr Response
  RequestRef* = ref Request

var
  httpIn*: AsyncPColl[ptr Request]
  httpOut*: AsyncTable[ptr Request, bool]

proc initHttp*() =
  if not httpIn.isnil:
    delete(httpIn)
  httpIn = newAsyncPColl[ptr Request]()
  if httpOut.isnil:
    httpOut = newAsyncTable[ptr Request, bool]()

converter asDec*(b: bool): Decode =
  if b: Decode.yes
  else: Decode.no


proc key*(s: string): array[5, byte] =
  case s.len
    of 0: result = default(array[5, byte])
    else:
      let ln = s.len
      result = cast[array[5, byte]]([s[0], s[ln /% 4], s[ln /% 3], s[ln /% 2],
          s[ln - 1]])

proc hash*(q: ptr Request): Hash = hash((q.id, q.meth, key(q.url.hostname), key(
    q.url.path), key(q.body)))

proc init*(r: var Request, url: Uri, met: HttpMethod = HttpGet,
             headers: HttpHeaders = nil, body = "", redir = true,
                     proxied = true, retries = 3) =
  r.id = getMonoTime()
  r.url = url
  r.meth = met
  r.body = body
  r.headers = headers
  r.redir = redir
  r.proxied = proxied
  r.retries = retries
