import std/sequtils

type
  Mutator[T, V] = proc(el: T): V {.gcsafe.}
  Predicate[V] = proc(el: V): bool {.gcsafe.}
  Generator*[T, V] = object
    current: int
    s: seq[T]
    get: Mutator[T, V]


proc newGen*[T, V](s: sink openarray[T], get: Mutator[T, V]): Generator[T, V] =
  result.s = s.toSeq
  result.get = get
  result.current = result.s.low

proc default*[T, V](_: typedesc[Generator[T, V]]): Generator[T, V] =
  result.current = -1
  echo result.s.high

proc nextImpl*[T, V](g: var Generator[T, V]): V =
  if likely(g.s.high != -1):
    result = g.get(g.s[g.current])
    if unlikely(g.current >= g.s.high):
      g.current = g.s.low
    else:
      g.current.inc

proc next*[T, V](g: var Generator[T, V]): V =
  g.nextImpl()

proc filterNext*[T, V](g: var Generator[T, V], pred: Predicate[V]): V =
  var v: V
  while true:
    v = g.nextImpl()
    if pred(v):
      return v
    if g.current == g.s.low:
      break
