import std/[importutils, tables]

type
  OrderedTableIterator*[K, V] = object
    tbl*: OrderedTable[K, V]
    next: int
  OrderedTableIteratorRef[K, V] = ref OrderedTableIterator[K, V]

privateAccess(OrderedTable)
proc initTableIterator*[K, V](_: typedesc[
    OrderedTableIterator]): OrderedTableIterator[K, V] =
  privateAccess(OrderedTable)
  new(result.tbl)
  result.tbl[] = initOrderedTable[K, V]()
  result.next = result.tbl.first

proc initTableIterator*[K, V](_: typedesc[OrderedTableIterator],
    tbl: OrderedTable[K, V]): OrderedTableIterator[K, V] =
  privateAccess(OrderedTable)
  result.tbl = tbl
  result.next = result.tbl.first

template nextImpl() =
  privateAccess(OrderedTable)
  let this {.inject.} =
    if t.next <= 0: t.tbl.data[t.tbl.first]
    else: t.tbl.data[t.next]
  t.next = this.next

proc next*[K, V](t: var OrderedTableIterator[K, V]): V =
  nextImpl()
  result = this.val

proc nextKey*[K, V](t: var OrderedTableIterator[K, V]): K =
  nextImpl()
  result = this.key
