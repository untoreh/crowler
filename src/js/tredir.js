import { $, $$ } from "./lib.js";
import { mainTr, mainContentEl } from "./app.js"

const Http = new XMLHttpRequest();
Http.timeout = 60000; // 60 secs
const captsRgx = /(\/+amp(?=\/+|(?=[?].*)|$))?(\/[a-z]{2}(?:-[A-Z]{2})?(?=\/+|(?=[?].*)|$))?(\/+.*?(?=\/+|(?=[?].*)|$))?(\/+(?:[0-9]+|s|g|feed\.xml|sitemap\.xml)(?=\/+|(?=[?].*)|$))?(\/+.*?(?=\/+|(?=[?].*)|$))?/;

function unPrefix(s) {
  if (typeof (s) != 'undefined') {
    return s.replace(/^\//, "")
  } else {
    return s
  }
}

function uriTuple() {
  let o = Object()
  let m = window.location.pathname.match(captsRgx)
  o.amp = unPrefix(m[1])
  o.lang = unPrefix(m[2])
  o.topic = unPrefix(m[3])
  o.page = unPrefix(m[4])
  o.art = unPrefix(m[5])
  return o
}

const trBox = document.createElement('div');
trBox.setAttribute("class", "translationNotification")
const trIcon = document.createElement('div');
trIcon.setAttribute("class", "loader")
const srcLangIcon = document.createElement('span');
srcLangIcon.classList.add("flag", "src")
const trgLangIcon = document.createElement('span');
trgLangIcon.classList.add("flag", "trg")
const trBar = document.createElement("div")
trBar.classList.add("loadbar")
trBox.appendChild(srcLangIcon)
trBox.appendChild(trIcon)
trBox.appendChild(trgLangIcon)
trBox.appendChild(trBar)
var already_translated = false;


function sleep(time) {
  return new Promise((resolve) => setTimeout(resolve, time));
}

function isTrReq(e) {
  let u = new URL(e.target.responseURL)
  let params = new URLSearchParams(u.search)
  return typeof params.get('t') != 'undefined'
}


Http.onreadystatechange = (e) => {
  try {
    if (isTrReq(e)) {
      let resp = Http.responseText
      if (resp.startsWith("<!doctype") || resp.startsWith("<!DOCTYPE")) {
        let domTr = (new DOMParser()).parseFromString(resp, "text/html")
        let mainTr = $("main", domTr)
        if (mainTr) {
          trBox.classList.remove("waiting")
          sleep(100).then(() => {
            mainContentEl.replaceWith(mainTr)
            already_translated = true;
          })
        }
      }
    }
  } catch {}
}

Http.ontimeout = (e) => {
  try {
    if (isTrReq(e)) {
      trBar.classList.add("fail")
      trIcon.classList.add("fail")
      srcLangIcon.style.animationName = "unset"
      srcLangIcon.style.display = "none"
      trgLangIcon.style.animationName = "unset"
      trgLangIcon.style.display = "none"
      trBox.style.pointerEvents = "none";
      trBox.style.transition = "1s ease-out opacity";
      trBox.style.opacity = 0;
    }
  } catch {}
}

const countryLangs = {
  "ar": "sa",
  "en": "gb",
  "el": "gr",
  "hi": "in",
  "pa": "in",
  "ja": "jp",
  "jw": "id",
  "bn": "bd",
  "tl": "ph",
  "zh": "cn",
  "zh-CN": "cn",
  "ko": "kr",
  "uk": "ua",
  "zu": "za",
  "vi": "vn",
  "ur": "pk",
  "sv": "se"
}

function toFlagLang(iso2) {
  if (iso2 in countryLangs) {
    return countryLangs[iso2]
  } else {
    return iso2
  }
}

function getMeta(name) {
  let m = $(`head meta[name=${name}]`)
  if (m) { return m.getAttribute("content") } else { return "" }
}

export function ensureTranslation() {
  let capts = uriTuple()
  let orig = getMeta("srclang")
  if (orig && getMeta("translation") == "processing") {
    $("body").appendChild(trBox)
    srcLangIcon.classList.add("flag-" + toFlagLang(orig))
    if (toFlagLang(capts.lang) == null) {
      console.log(capts)
    }
    trgLangIcon.classList.add("flag-" + toFlagLang(capts.lang))
    trBox.classList.add("waiting")
    let loc = window.location
    let newUrl = loc.protocol + "//" + loc.hostname + ":" + loc.port + loc.pathname
    let params = new URLSearchParams(loc.search)
    params.set("t", 1)
    // console.log("Waiting for translation! " + newUrl + "?" + params.toString())
    Http.open("GET", newUrl + "?" + params.toString());
    Http.send();
  }
}
