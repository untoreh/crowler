import prologue
import strformat

proc main*(ctx: Context) {.async.} =
  resp &"<h1>{ctx.handled}</h1>"

let app = newApp()
app.get("/", hello)
app.run()
