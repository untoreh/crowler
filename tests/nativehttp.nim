
when isMainModule:
  initHttp()
  proc f() {.async.} =
    let u = "https://ipinfo.io/ip".parseUri
    let resp = await get(u, proxied = false)
    echo resp.code
    echo resp.body
  waitFor f()
