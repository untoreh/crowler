## This function iterates on an article and wraps one word every `chunksize` chars  with ad links.
proc insertAds*(str: string, chunksize = 2500, lang = "", topic = "",
                  kws: seq[string] = @[], staticLinks: static[
                      bool] = false): Future[string] {.async.} =
  ## chunksize is the number of chars between ads

  var linksGen =
    when staticLinks: adsGen(adsLinks)
    else: await adsLinksGen(topic, kws, lang, getter = url)
  if linksGen.len == 0:
    return str

  var maxsize = str.len
  var chunkpos = if chunksize >= maxsize: maxsize.div(2)
                else: chunksize
  var positions: seq[int]
  while chunkpos <= maxsize:
    positions.add(chunkpos)
    chunkpos += chunksize
  positions.reverse()

  var s = newStringStream(str)
  if s == nil:
    raise newException(CatchableError, "ads: cannot convert str into stream")
  var x: XmlParser
  var txtpos, prevstrpos, strpos: int
  var filled: bool
  open(x, s, "")
  defer: close(x)
  while true:
    next(x)
    case x.kind:
      of xmlCharData:
        let
          txt = x.charData
          txtStop = txt.len
        prevstrpos = strpos
        strpos = x.offsetBase + x.bufpos - txtStop
        # add processed non text data starting from previous point
        if strpos > prevstrpos:
          let tail = str[prevstrpos..strpos - 1]
          # FIXME: The xmlparser never appears to output `xmlEntity` events
          # and deals with entities in a strange way
          if (tail & ";").isEntity:
            doassert txt[0] != str[strpos + 1]
            result.add tail
            result.add ';' # the xmlparser skips the semicolon
            strpos += 1
            continue
          else:
            result.add tail
            if str[strpos] == '>': # FIXME: this shouldn't be required...
              result.add '>'
              strpos += 1
        strpos += txtStop # add the current text to the current string position

        if unlikely(positions.len == 0):
          result.add txt
          continue
        for (w, isSep) in txt.tokenize():
          txtpos += w.len
          if txtpos > positions[^1]:
            if (not isSep) and (w.len > 5):
              let link = buildhtml(a(href = linksGen.next,
                  class = "ad-link")): text w
              result.add $link
              discard positions.pop()
            else:
              result.add w
            if positions.len == 0:
              if txtpos <= txt.len:
                result.add txt[txtpos..^1]
              break
          else:
            result.add w
      of xmlEof:
        break
      else:
        if filled:
          break
