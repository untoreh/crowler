when isMainModule:
  initHttp()
  var gt = init(GoogleTranslateObj)
  var text = """This was a fine day."""
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Buddy please help."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Not right now, maybe tomorrow."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "The greatest glory in living lies not in never falling, but in rising every time we fall."
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "The way to get started is to quit talking and begin doing"
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "Your time is limited, so don't waste it living someone else's life"
  wrap echo waitFor gt[].translate(text, "en", "it")
  text = "If life were predictable it would cease to be life, and be without flavor"
  wrap echo waitFor gt[].translate(text, "en", "it")
  import os
  sleep(100000)
