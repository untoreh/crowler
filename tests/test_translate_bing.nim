when isMainModule:
  initHttp()
  var bt = init(BingTranslateObj)
  # let bc = waitFor bt[].fetchBingConfig()
  # echo bt[].isTokenExpired()
  # echo bc.tokenTs
  # echo bc.tokenExpiryInterval
  let what = "Hello, how are you?"
  echo waitFor bt.translate(what, "auto", "it")
