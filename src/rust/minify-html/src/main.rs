// #![feature(type_name_of_val)]
use minify_html::{Cfg, minify as minify_html_native};
use std::ffi::CStr;
use std::ffi::CString;
use std::os::raw::c_char;
// use std::str;
// use std::io::{self, Write};
// use std::{thread, time};

// use mimalloc::MiMalloc;

// #[global_allocator]
// static GLOBAL: MiMalloc = MiMalloc;

// use std::boxed::Box;
// use std::any::type_name_of_val;

#[no_mangle]
pub extern "C" fn minify(
    code: *const c_char,
    do_not_minify_doctype: bool,
    ensure_spec_compliant_unquoted_attribute_values: bool,
    keep_closing_tags: bool,
    keep_comments: bool,
    keep_html_and_head_opening_tags: bool,
    keep_spaces_between_attributes: bool,
    minify_css: bool,
    minify_js: bool,
    remove_bangs: bool,
    remove_processing_instructions: bool,
) -> *const c_char {

    let code = unsafe { CStr::from_ptr(code) };
    let code_vec = code.to_bytes();

    let cfg = Cfg {
        do_not_minify_doctype,
        ensure_spec_compliant_unquoted_attribute_values,
        keep_closing_tags,
        keep_comments,
        keep_html_and_head_opening_tags,
        keep_spaces_between_attributes,
        minify_css,
        minify_js,
        remove_bangs,
        remove_processing_instructions,
    };

    let minified = minify_html_native(code_vec, &cfg);
    // thread::sleep(time::Duration::from_millis(1000));
    // println!("slept!");
    // io::stdout().flush().unwrap();

    let s = unsafe { CString::from_vec_unchecked(minified).into_raw() };
    return s;
    // let c_s = CString::new("ok").unwrap();
    // return c_s.into_raw();
    // Ok(String::from_utf8(out_code).unwrap())
}


// fn minify_code(code: &String) -> String {
//     let cfg = Cfg::new();
//     return String::from_utf8(minify_html_native(code.as_bytes(), &cfg)).unwrap();
// }

fn main() {
    // let html = &String::from("<!doctype html> <body> asd </body> </html>");
    // for _ in 1..10 {
    //     let minified  = minify_code(html);
    //     println!("{}", minified);
    //     thread::sleep(time::Duration::from_millis(1000));
    // }
}
