import chronos
import ../src/nim/imageflow
import ../src/nim/nativehttp

when isMainModule:
  initHttp()
  initImageFlow()
  let img = "https://picjumbo.com/wp-content/uploads/maltese-dog-puppy-1570x1047.jpg"
  # let img = PROJECT_PATH / "vendor" / "imageflow.dist" / "data" / "cat.jpg"
  # let data = waitFor getImg(img, kind = urlsrc)
  let data = readFile("/tmp/wat")
  # echo data.len
  echo "imageflow.nim:230"
  doassert data.addImg
  echo "imageflow.nim:232"
  let query = "width=100&height=100&mode=max"
  echo "imageflow.nim:234"
  let (i, mime) = processImg(query)
  echo "imageflow.nim:236"
  echo mime
  echo i.len
