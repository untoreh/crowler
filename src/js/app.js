import { MDCRipple } from '@material/ripple';
import { MDCTopAppBar } from '@material/top-app-bar';
import {MDCTextField} from '@material/textfield';
// import {MDCTooltip} from '@material/tooltip';

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

window.onload = function() {
    // dark light
    document.querySelector(".dk-toggle").onclick = toggleTheme;
    toggleTheme();

    // button
    const iconButtonRipple = new MDCRipple(document.querySelector('.mdc-icon-button'));
    iconButtonRipple.unbounded = true;

    // appbar
    const topAppBarElement = document.querySelector('.mdc-top-app-bar');
    const topAppBar = new MDCTopAppBar(topAppBarElement);

    // ripples
    const surface = document.querySelector('.mdc-ripple-surface');
    const ripple = new MDCRipple(surface);

    // search
    const textField = new MDCTextField(document.querySelector('.mdc-text-field'));
}
