import std/[importutils, tables]

type
  OrderedTableIteratorObj[K, V] = object
    tbl*: ptr OrderedTable[K, V]
    next: int
  OrderedTableIterator*[K, V] = ref OrderedTableIteratorObj[K, V]

proc initTableIterator*[K, V](_: typedesc[OrderedTableIterator],
    tbl: ptr OrderedTable[K, V]): OrderedTableIterator[K, V] =
  privateAccess(OrderedTable)
  new(result)
  result.tbl = tbl
  result.next = result.tbl.first

template nextImpl() =
  privateAccess(OrderedTable)
  let this {.inject.} =
    if t.next <= 0: t.tbl.data[t.tbl.first]
    else: t.tbl.data[t.next]
  t.next = this.next

proc next*[K, V](t: OrderedTableIterator[K, V]): V =
  nextImpl()
  result = this.val

proc nextKey*[K, V](t: OrderedTableIterator[K, V]): K =
  nextImpl()
  result = this.key
