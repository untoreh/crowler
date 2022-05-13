import regeneratorRuntime from "regenerator-runtime";

const Http = new XMLHttpRequest();
var suggestUrl
var form, sug, sel, cursel, suggest, sugLast, closebtn
import { $, $$ } from "./lib.js";
const sugThrottle = 333

Http.onreadystatechange = (e) => {
    let resp = Http.responseText
    if (resp.startsWith("<ul")) {
        suggest.outerHTML = resp
        suggest = $(".search-suggest", form)
        toggleSelection()
    }
    cursel = $("li.selected", suggest)
}

function querySuggest(e) {
    let v = e.target.value
    if (v != "") {
        const query = {
            q: v,
        };
        const params = new URLSearchParams(query);
        Http.open("GET", suggestUrl + params.toString());
        Http.send();
    }
}

function visible(el, t = true) {
    let disp = el.style.display
    if (t) {
        if (disp != "initial") {
            el.style.display = "initial"
        }
    } else {
        if (disp != "none") {
            el.style.display = "none"
        }
    }
}

const waitFor = delay => new Promise(resolve => setTimeout(resolve, delay));
async function delayedSuggest(e) {
    await waitFor(sugThrottle)
    let now = Date.now()
    if ((now - sugLast) > sugThrottle) {
        querySuggest(e)
    }
}

function updateValue(e) {
    let now = Date.now()
    visible(closebtn, e.target.value != "")
    if ((now - sugLast) < sugThrottle) {
        delayedSuggest(e)
    } else {
        sugLast = now
        querySuggest(e)
    }
}

function deselect(_) {
    if (cursel) {
        cursel.classList.remove("selected")
    }
}
function select(_) {
    if (cursel) {
        cursel.classList.add("selected")
    }
}
function toggleSelection(el = suggest) {
    el.addEventListener("mouseenter", deselect)
    el.addEventListener("mouseleave", select)
}

function setupInput() {
    toggleSelection()
    $(".search-input", form).addEventListener("keydown", function (e) {
        let suggest = $(".search-suggest", form)
        switch (e.which) {
            case 40:
                e.preventDefault()
                sel = $('li:not(:last-child).selected', suggest)
                if (sel) {
                    sel.classList.remove("selected")
                    cursel = sel.nextElementSibling
                    cursel.classList.add('selected');
                }
                break;
            case 38:
                e.preventDefault()
                sel = $('li:not(:first-child).selected', suggest)
                if (sel) {
                    sel.classList.remove("selected")
                    cursel = sel.previousElementSibling
                    cursel.classList.add('selected');
                }
                break;
            case 13: // Enter
                e.preventDefault()
                let url = $("a", cursel).getAttribute("href")
                window.location = url
                break;
        }
    });
}

export function setupSuggest() {
    sugLast = new Date().getTime()
    form = $("form.search")
    suggest = $(".search-suggest", form)
    closebtn = $(".clear-search-btn", form)
    const topic = $("body").getAttribute("topic")
    suggestUrl = "/" + topic + "/g/suggest?";
    form.addEventListener("input", updateValue);
    setupInput()
    $("html,body").addEventListener("click", (e) => {
        let el = e.target
        if (!el.classList.contains("selected")) {
            visible(suggest, false)
        }
    })
    closebtn.addEventListener("click", (e) => {
        $(".search-input", form).value = ""
        e.preventDefault()
        visible(closebtn, false)
    })
}
