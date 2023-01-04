use once_cell::sync::Lazy;
use sonic_channel::*;
use std::boxed::Box;
use std::ffi::*;

static mut global_conn: Lazy<Box<Option<Connection>>> = Lazy::new(|| Box::new(None));

fn to_str(s: *const c_char) -> String {
    unsafe {
        let host = CStr::from_ptr(s as *const i8).to_str().unwrap();
        return host.to_string();
    };
}

fn to_c_array(v: Vec<String>) -> *const *const c_char {
    let mut c_array: Vec<*const c_char> = vec![std::ptr::null(); v.len() + 1];
    for n in 0..v.len() {
        let cs = CString::new(v[n].as_bytes()).unwrap();
        let p = CString::into_raw(cs);
        c_array[n] = p;
    }
    assert!(c_array.last().unwrap().is_null());
    assert!(c_array.len() == c_array.capacity()); // for reconstruction
    let p = c_array.as_ptr();
    std::mem::forget(c_array);
    p
}

// use std::ptr;
#[no_mangle]
pub unsafe extern "C" fn destroy_response(arr: *mut *const c_char) {
    let mut len = 1;
    let pos = arr;
    while !(*pos.add(len)).is_null() {
        len += 1;
    }
    let v: Vec<*const c_char> = Vec::from_raw_parts(arr, len, len);
    for p in v {
        if !p.is_null() {
            let _ = CString::from_raw(p as *mut c_char);
        }
    }
}

#[repr(C)]
pub struct Connection {
    search: SearchChannel,
    ingest: IngestChannel,
    control: ControlChannel,
}

fn _connect(host: &str, pass: &str) -> Connection {
    let search = SearchChannel::start(host, pass).unwrap();
    let ingest = IngestChannel::start(host, pass).unwrap();
    let control = ControlChannel::start(host, pass).unwrap();
    return Connection {
        search,
        ingest,
        control,
    };
}

#[no_mangle]
pub extern "C" fn sonic_connect(
    host: *const c_char,
    pass: *const c_char,
) -> *const Option<Connection> {
    let (host, pass) = (to_str(host), to_str(pass));
    let conn = _connect(&host, &pass);
    unsafe {
        **global_conn = Some(conn);
        let b = Lazy::get(&global_conn).unwrap();
        return b.as_ref();
    }
}

fn default_buc(buc: &str) -> &str {
    return if buc.chars().count() == 0 {
        "default"
    } else {
        buc
    };
}

fn _query(
    conn: &Connection,
    col: &str,
    buc: &str,
    kws: &str,
    lang: &str,
    limit: usize,
) -> Vec<String> {
    let buc = default_buc(buc);
    let mut rq = QueryRequest::new(Dest::col_buc(col, buc), kws);
    let lang = Lang::from_code(lang);
    if lang.is_some() {
        rq = rq.lang(lang.unwrap());
    }
    rq = rq.limit(limit);
    let res = conn.search.query(rq);
    return res.unwrap_or_default();
}

#[no_mangle]
pub unsafe extern "C" fn is_open(conn: *const Connection) -> bool {
    return _push(&(*conn), &"default", &"default", &".", &".", &"");
}

fn _suggest(conn: &Connection, col: &str, buc: &str, input: &str, limit: usize) -> Vec<String> {
    let mut rq = SuggestRequest::new(Dest::col_buc(col, buc), input);
    rq = rq.limit(limit);
    return conn.search.suggest(rq).unwrap_or_default();
}

#[no_mangle]
pub extern "C" fn suggest(
    conn: *const Connection,
    col: *const c_char,
    buc: *const c_char,
    input: *const c_char,
    limit: usize,
) -> *const *const c_char {
    let (col, buc, input) = (to_str(col), to_str(buc), to_str(input));
    unsafe {
        return to_c_array(_suggest(&(*conn), &col, &buc, &input, limit));
    }
}

#[no_mangle]
pub extern "C" fn query(
    conn: *const Connection,
    col: *const c_char,
    buc: *const c_char,
    kws: *const c_char,
    lang: *const c_char,
    limit: usize,
) -> *const *const c_char {
    let (col, buc, kws, lang) = (to_str(col), to_str(buc), to_str(kws), to_str(lang));
    unsafe {
        let res = _query(&*conn, &col, &buc, &kws, &lang, limit);
        return to_c_array(res);
    }
}

fn _push(conn: &Connection, col: &str, buc: &str, key: &str, cnt: &str, lang: &str) -> bool {
    let buc = default_buc(buc);
    let od = ObjDest::new(Dest::col_buc(col, buc), key.to_string());
    let mut rq = PushRequest::new(od, cnt);
    let lang = Lang::from_code(lang);
    if lang.is_some() {
        rq = rq.lang(lang.unwrap());
    }
    return conn.ingest.push(rq).is_ok();
}

#[no_mangle]
pub extern "C" fn push(
    conn: &Connection,
    col: *const c_char,
    buc: *const c_char,
    key: *const c_char,
    cnt: *const c_char,
    lang: *const c_char,
) -> bool {
    let (col, buc, key, cnt, lang) = (
        to_str(col),
        to_str(buc),
        to_str(key),
        to_str(cnt),
        to_str(lang),
    );
    unsafe {
        return _push(conn, &col, &buc, &key, &cnt, &lang);
    }
}

fn _flush(conn: &Connection, col: &str, buc: &str, obj: &str) {
    let rq = match (col, buc, obj) {
        (col, "", "") => FlushRequest::collection(col),
        (col, buc, "") => FlushRequest::bucket(col, buc),
        (col, buc, obj) => FlushRequest::object(col, buc, obj),
    };
    unsafe {
        conn.ingest.flush(rq).unwrap_or_default();
    }
}

#[no_mangle]
pub extern "C" fn flush(
    conn: *const Connection,
    col: *const c_char,
    buc: *const c_char,
    obj: *const c_char,
) {
    let (col, buc, obj) = (to_str(col), to_str(buc), to_str(obj));
    unsafe {
        _flush(&*conn, &col, &buc, &obj);
    }
}

#[no_mangle]
pub unsafe extern "C" fn consolidate(conn: *const Connection) {
    (*conn).control.consolidate().unwrap_or_default();
}

#[no_mangle]
pub unsafe extern "C" fn quit(conn: *const Connection) -> bool {
    return (*conn).ingest.quit().is_ok()
        && (*conn).search.quit().is_ok()
        && (*conn).control.quit().is_ok();
}

use std::alloc::{dealloc, Layout};
use std::ptr::drop_in_place;
#[no_mangle]
pub unsafe extern "C" fn destroy(ptr: *mut Connection) {
    drop_in_place(ptr);
    dealloc(ptr as *mut u8, Layout::new::<Connection>());
}

pub fn main() {
    // let (host, pass) = ("localhost:1491", "dmdm");
    // let conn = _connect(host, pass);
    // let res = _query(
    //     &conn as *&Connection,
    //     "wsl",
    //     "default",
    //     "mini",
    //     "",
    //     100,
    // );
}
