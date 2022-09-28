import chronos/timer
from std/times import fromUnix, inZone, local, format, getTime
import uuids
export uuids

type
  CachedUUID* = ref object
    value*: UUID
    expiration: Moment
    duration*: Duration

proc newCachedUUID*(duration = 360.seconds): CachedUUID =
  result = new(CachedUUID)
  result.value = genUUID()
  result.duration = duration
  result.expiration = Moment.now() + duration

proc refresh*(uuid: CachedUUID): bool =
  let t = Moment.now()
  if (t > uuid.expiration):
    uuid.value = genUUID()
    uuid.expiration = t + uuid.duration
    return true

proc `$`*(uuid: CachedUUID): string =
  "uuid: " & $uuid.value & " duration: " & $uuid.duration.seconds & "s"
