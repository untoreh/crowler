import std/[monotimes, uri, httpcore, strutils, net, tables]
import chronos
import httptypes
import macros
from cfg import PROXY_EP
export PROXY_EP
export httpcore

const
  DEFAULT_TIMEOUT* = 3.seconds

type TranslateError* = object of ValueError
proc raiseTranslateError*(msg: string) =
  raise newException(TranslateError, msg)

type
  Query* = tuple[id: MonoTime, text: string, src: string, trg: string, trans: ref string]
  TranslateFunc* = proc(text, src, trg: string): Future[string] {.gcsafe.}
  Service* = enum google, bing, yandex
  TranslateObj* = object of RootObj
    kind*: Service
    maxQuerySize*: int
  Translate*[T: TranslateObj] = ref T
  TranslatePtr*[T: TranslateOBj] = ptr T

proc init*[T: TranslateObj](_: typedesc[T], useProxies = true): T =
  result.maxQuerySize = 5000

proc parseCookies*(resp: Response): string =
  for ck in resp.headers.table.getOrDefault("set-cookie"):
    let cks = ck.split(';')
    if len(cks) > 0:
      result.add cks[0]
      result.add "; "
