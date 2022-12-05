import std/sequtils

type
  Mutator[T, V] = proc(el: T): V {.gcsafe.}
  Predicate[V] = proc(el: V): bool {.gcsafe.}
  Generator*[T, V] = object
    current: int
    s: seq[T]
    get: Mutator[T, V]
  Iterator*[T] = object
    current: int
    s: seq[T]


proc newGen*[T, V](s: sink openarray[T], get: Mutator[T, V]): Generator[T, V] =
  result.s = s.toSeq
  result.get = get
  result.current = result.s.low

proc newIter*[T](s: sink openarray[T]): Iterator[T] =
  result.s = s.toSeq
  result.current = result.s.low

proc default*[T, V](_: typedesc[Generator[T, V]]): Generator[T, V] =
  result.current = -1
  echo result.s.high

template nextImpl(mut: static[bool] = false) =
  if likely(g.s.high != -1):
    result = when mut: g.get(g.s[g.current])
             else: g.s[g.current]
    if unlikely(g.current >= g.s.high):
      g.current = g.s.low
    else:
      g.current.inc

proc nextImplIter*[T](g: var Iterator[T]): T = nextImpl()
proc nextImplGen*[T, V](g: var Generator[T, V]): V = nextImpl(true)

proc next*[T, V](g: var Generator[T, V]): V = g.nextImplGen()
proc next*[T](g: var Iterator[T]): T = g.nextImplIter()
proc len*[T](g: var Iterator[T]): int = g.s.len
proc len*[T, V](g: var Generator[T, V]): int = g.s.len

proc filterNext*[T, V](g: var Generator[T, V], pred: Predicate[V]): V =
  var v: V
  while true:
    v = g.nextImplGen()
    if pred(v):
      return v
    if g.current == g.s.low:
      break

proc filterNext*[T](g: var Iterator[T], pred: Predicate[T]): T =
  var v: T
  while true:
    v = g.nextImplIter()
    if pred(v):
      return v
    if g.current == g.s.low:
      break
