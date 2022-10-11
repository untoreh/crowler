# https://github.com/mashingan/nim-etc/blob/master/sharedseq.nim
import locks
#TODO: For ref type element deletion
#import typeinfo

type
  Coll*[T] = object
    ## Box for linear position value in memory. The representation of
    ## linear position is a pointer of given type. It has its own guard/lock
    ## to ensure avoiding race-condition.
    ## The pointer object is created with ``create`` instead of ``createShared``
    ## so make sure the object lifetime longer than its ``coll`` field.
    coll {.guard: lock.}: ptr T   ## Consecutive array pointer of
                                  ## given type in memory.
    size: int                     ## Size the collection.
    lock: Lock                    ## Guard for ``coll`` field.

  PColl*[T] = ptr Coll[T]         ## Pointer representation of ``Coll``

template guardedWith[T](coll: PColl[T], body: untyped) =
  {.locks: [coll.lock].}:
    body

proc newColl*[T](): PColl[T] =
  ## Default constructor with zero arity
  result = create(Coll[T], 1)
  initLock result.lock
  guardedWith result: result.coll = createShared(T, 1)
  result.size = 0

proc newColl*[T](size = 0, init: T): PColl[T] =
  ## Default constructor with initial value defined
  var newsize: int
  if size == 0:
    newsize = 1
  result = create(Coll[T], newsize)
  initLock result.lock
  guardedWith result:
    result.coll = createShared(T, newsize)
    result.coll[] = init
  result.size = newsize

proc freeColl*(p: PColl, ){.discardable.} =
  ## Freeing the allocated shared memory
  deinitLock p.lock
  when compiles(delete p[0]):
    for i in 0 ..< p.size:
      delete p[i]
  if p.size > 0:
    guardedWith p: p.coll.freeShared
  p.dealloc


template `+`[T](p: ptr T, ofs: int): ptr T =
  cast[ptr p[].type](cast[ByteAddress](p) +% ofs * p[].sizeof)

template `[]`[T](p: ptr T, ofs: int): T =
  (p+ofs)[]

template `[]=`[T](p: ptr T, ofs: int, val: T) =
  (p+ofs)[] = val

proc `[]`*[T](p: PColl[T], ofs: int): T =
  ## Getting the index value. O(1)
  guardedWith p:
    result = p.coll[ofs]

proc `[]=`*[T](p: PColl[T], ofs: int, val: T) =
  ## Setting the value at index. O(1)
  guardedWith p:
    p.coll[ofs] = val

proc `$`*(p: PColl): string =
  ## Stringify the collection
  result = "["
  for i in 0..<p.size:
    guardedWith p:
      result &= $p.coll[i]
    if i != p.size - 1:
      result &= ", "
  result &= "]"

proc len*(p: PColl): int =
  ## Getting the size of collection
  p.size

proc inc*[T](p: var ptr T) {.discardable.} =
  ## Increment the pointer position
  p = p + 1

proc contains*[T](p: ptr T, x: T): bool =
  ## Check whether ``x`` in ``p``. Can be used with ``in`` expression
  ##
  ## .. code-block:: nim
  ##  if x in coll:
  ##    echo $x
  ##
  var temp = p
  for i in 0..<p.len:
    if x == temp[]:
      return true
    inc temp
  false

proc contains*[T](p: PColl[T], val: T): bool =
  ## Check whether ``val`` in ``p``.
  result = false
  for i in 0..<p.size:
    guardedWith p:
      if val == p.coll[i]:
        result = true
        break

#[
template kindof[T](x: var T, whatKind: AnyKind) =
  ## To get what kind of ``x`` type. To find whether ``x`` is value or
  ## reference type.
  whatKind = toAny[T](x).kind
  cast[T](x)
]#

proc delete*(p: PColl){.discardable.} = p.freeColl

proc delete*(p: PColl, idx: int){.discardable.} =
  ## Delete the value at index position and move all the subsequent values
  ## to fill its respective previous position. O(n)

  if idx > p.size:
    return

  # TODO: Implement for checking whether it's value type or reference type
  # To delete the element that some kind of user defined object which
  # created with some memory allocation, user need to define ``delete``
  # operation to its object in order to free the memory.

  #[
  #TODO: Finish individual reference type element deletion
  var
    thekind: AnyKind
    tempvar = p[0]
  kindof tempvar, theKind
  let isBasicObj: bool = case theKind
    of akObject, akPtr, akProc, akCstring: false
    else: true
  ]#

  var temp: ptr p[0].type
  guardedWith p:
    temp = p.coll + idx + 1
    p.coll[idx] = temp[]
  inc temp
  for i in idx+1..<p.size:
    if temp.isNil:
      break
    guardedWith p:
      when compiles(delete p.coll[i]):
        # TODO: Fix this to foolproof the memory type
        # Rely ``PColl`` users to implement ``delete`` proc for its individual
        # element. If there's no ``delete`` function implemented, will
        # the position will be overwritten with other value. The it's the
        # reference type especially ``pointer`` or ``ptr T``, this will leak
        delete p.coll[i]
      p.coll[i] = temp[]
    inc temp

  dec p.size
  guardedWith p:
    p.coll = resizeShared(p.coll, p.size)


proc add*[T](p: var PColl, val: T) {.discardable.} =
  ## Append the ``val`` to ``p``. O(1)
  guardedWith p:
    p.coll = resizeShared(p.coll, p.size+1)
  if p.size == 0:
    p[0] = val
  else:
    p[p.size] = val
  inc p.size

proc pop*[T](p: PColl, val: var T): bool  =
  ## Append the ``val`` to ``p``. O(1)
  guardedWith p:
    if p.len > 0:
      val = p[0]
      p.delete(0)
      result = true

when defined(checkMemStat):
  proc getCollSize(p: var PColl): int =
    p[0].sizeof * p.len
