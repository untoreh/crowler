import std/[uri, httpcore, monotimes, hashes]
export monotimes
import locktplutils
type
  TimeoutError* = object of CatchableError
  RequestError* = object of CatchableError

type
  Decode* = enum no, yes
  Request* = object
    id*: MonoTime
    url*: Uri
    meth*: HttpMethod
    headers*: HttpHeaders
    body*: string
    redir*: bool
    decode*: Decode
    proxied*: bool
  RequestRef* = ref Request

  Response* = object
    code*: HttpCode
    headers*: ptr HttpHeaders
    body*: ptr string
    size*: int
  ResponseRef* = ref Response

var
  httpIn*: AsyncPColl[ptr Request]
  httpOut*: AsyncTable[ptr Request, ptr Response]

proc initHttp*() =
  if not httpIn.isnil:
    delete(httpIn)
  httpIn = newAsyncPColl[ptr Request]()
  if httpOut.isnil:
    httpOut = newAsyncTable[ptr Request, ptr Response]()

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

proc init*(r: var Response) {.inline.} =
  r.headers = create(HttpHeaders)
  r.body = create(string)

proc newResponse*(): ptr Response {.inline.} =
  result = create(Response)
  init(result[])

proc init*(r: var Request, url: Uri, met: HttpMethod = HttpGet,
             headers: HttpHeaders = nil, body = "", redir = true,
                 proxied = true) =
  r.id = getMonoTime()
  r.url = url
  r.meth = met
  r.body = body
  r.headers = headers
  r.redir = redir
  r.proxied = proxied

proc free*(o: ptr Response) =
  if not o.isnil:
    o.code.reset
    if not o.headers.isnil:
      o.headers.reset
    if not o.body.isnil:
      o.body.reset
    dealloc o
