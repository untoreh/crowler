import std/[uri, httpcore]

type
  TimeoutError* = object of CatchableError
  RequestError* = object of CatchableError

type
  Request* = object
    url*: Uri
    meth*: HttpMethod
    headers*: HttpHeaders
    body*: string
    redir*: bool
  RequestPtr* = ptr Request

  Response* = object
    code*: HttpCode
    headers*: HttpHeaders
    body*: string
  ResponsePtr* = ptr Response
