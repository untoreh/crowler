
from libsonic as sonic import nil
var host = "localhost:1491"
var pass = "dmdm"
let conn = sonic.sonic_connect(host = host[0].addr, pass = pass[0].addr)
assert not conn.isnil

var col = "wsl"
var bucket = "default"
var kws = "mini"
var lang = cstring("\0")

proc test() =
    let res = sonic.query(conn, col[0].addr, bucket[0].addr,
                            kws[0].addr, lang = lang[0].addr, limit = 10.csize_t)
    if not res.isnil:
      let arr = cast[cstringArray](res)
      # defer: deallocCstringArray(arr)
      defer: sonic.destroy_response(res)
      block:
        let sq = arr.cstringArrayToSeq()
        for s in sq:
          discard
          # echo s


for i in 0..1000000:
  test()

echo "test.nim:42"
# import os
# os.sleep(100000000)

when isMainModule:
  initSonic()
  # waitFor syncTopics(true)
  # waitFor pushAllSonic()
  debug "nice"
  let q = waitFor query("mini", "mini", "hello")
  echo q
  # let qq = waitFor query("mini", "mini", "es")
  # echo qq
  # debug "done"
  # let qq = waitFor suggest("mini", "mini")
  # echo qq
  # push(relpath)
  # discard controlClient.trigger("consolidate")
  # echo suggest("web", "web host")
