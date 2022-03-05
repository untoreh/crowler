import { MDCRipple } from "@material/ripple";
import { MDCTopAppBar } from "@material/top-app-bar";

function toggleTheme() {
  let el = document.body;
  if (el.classList.contains("dark")) {
    el.classList.remove("dark");
    el.classList.add("light");
  } else if (el.classList.contains("light")) {
    el.classList.remove("light");
    el.classList.add("dark");
  } else {
    if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
      el.classList.add("dark");
    } else {
      el.classList.add("light");
    }
  }
}

function toggleDrawer() {
  let el = document.querySelector(".menu-list");
  if (el.style.left !== "-100vh" && el.style.left !== "") {
    el.style.left = "-100vh";
  } else {
    el.style.left = "0";
  }
}

window.onload = function () {
  // dark light
  document.querySelectorAll(".dk-toggle").forEach(el => el.onclick = toggleTheme)
  toggleTheme();

  document.querySelector(".menu-btn").onclick = toggleDrawer;

  // button
  const iconButtonRipple = new MDCRipple(
    document.querySelector(".mdc-icon-button")
  );
  iconButtonRipple.unbounded = true;

  // appbar
  const topAppBarElement = document.querySelector(".mdc-top-app-bar");
  const topAppBar = new MDCTopAppBar(topAppBarElement);

  // ripples
  const surface = document.querySelector(".mdc-ripple-surface");
  const ripple = new MDCRipple(surface);

  const mainContentEl = document.querySelector("main");
  const menuBtn = document.querySelector(".menu-btn");

  topAppBar.setScrollTarget(mainContentEl);
};
