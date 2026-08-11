use std::ffi::{CStr, CString};
use std::os::raw::c_char;

// 住所を正規化する（ここは普通のRust。好きなだけ賢くできる）
fn normalize(input: &str) -> String {
    input
        .chars()
        .map(|c| match c {
            '０'..='９' => char::from_u32(c as u32 - '０' as u32 + '0' as u32).unwrap(),
            'ヶ' => 'ケ',
            'ー' | '－' | '−' => '-',
            other => other,
        })
        .collect()
}

#[unsafe(no_mangle)] // edition 2024 はこの書き方
pub extern "C" fn normalize_address(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let c_str = unsafe { CStr::from_ptr(input) };
    let rust_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let result = normalize(rust_str);
    CString::new(result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}
