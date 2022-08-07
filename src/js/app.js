import { MDCRipple } from "@material/ripple";
import { MDCTopAppBar } from "@material/top-app-bar";
import { getCookie, $, $$ } from "./lib.js";
import { setupSuggest } from "./suggest.js";
// import "../css/app.scss";
/** after `app.scss` **/
// import "uno.css";

function toggleTheme() {
  let el = document.body;
  if (el.classList.contains("dark")) {
    el.classList.remove("dark");
    el.classList.add("light");
  } else if (el.classList.contains("light")) {
    el.classList.remove("light");
    el.classList.add("dark");
  } else {
    let dT = getCookie("darkTheme");
    if (dT != "") {
      if (dT.split(" ")[0] === "true") {
        el.classList.add("dark");
      } else {
        el.classList.add("light");
      }
    } else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
      el.classList.add("dark");
    } else {
      el.classList.add("light");
    }
  }
  document.cookie = `darkTheme=${el.classList.contains(
    "dark"
  )}; SameSite=Strict`;
}

function toggleVisibility(el, hide = false) {
  if (hide || (el.style.left !== "-100vh" && el.style.left !== "")) {
    el.style.left = "-100vh";
  } else {
    el.style.left = "0";
  }
}

function toggleShow(el, hide = false) {
  if (hide) {
    el.classList.remove("show");
  } else {
    el.classList.toggle("show");
  }
}

function toggleDrawer(_, hide = false) {
  let el = $(".menu-list");
  toggleVisibility(el, hide);
}

function toggleLangs(e, hide = false) {
  let el = $(".langs-dropdown-content", e.target);
  // let el = e.target.nextElementSibling;
  // if (!el.classList.contains(".langs-dropdown-content")) {
  //   console.log("Can't find lang menu in clicked element")
  // }
  toggleShow(el, hide);
}

function closeMenus(e) {
  let el = e.target;
  let cls = el.classList;
  e.stopPropagation();
  if (!cls.contains("langs-dropdown-content") && !cls.contains("translate")) {
    let langs = $$(".langs-dropdown-content");
    langs.forEach((l) => toggleShow(l, true));
  }
  let pcls = el.parentElement.classList;
  if (
    !cls.contains("menu-btn") &&
    !cls.contains("menu-list") &&
    !pcls.contains("menu-list") &&
    !pcls.contains("menu-lang-btn")
  ) {
    toggleDrawer(null, true);
  }
}

window.onload = function () {
  // dark light
  $$(".dk-toggle").forEach((el) => (el.onclick = toggleTheme));
  toggleTheme();

  $("html,body").onclick = closeMenus;
  $(".menu-btn").onclick = toggleDrawer;
  $$(".menu-lang-btn").forEach((el) => (el.onclick = toggleLangs));

  // button
  const iconButtonRipple = new MDCRipple($(".mdc-icon-button"));
  iconButtonRipple.unbounded = true;

  // appbar
  const topAppBarElement = $(".mdc-top-app-bar");
  const topAppBar = new MDCTopAppBar(topAppBarElement);

  // ripples
  const surface = $(".mdc-ripple-surface");
  const ripple = new MDCRipple(surface);

  const mainContentEl = $("main");
  const menuBtn = $(".menu-btn");

  topAppBar.setScrollTarget(mainContentEl);
  setupSuggest();
};
