use serde_json::Value;
use std::ffi::c_void;
use std::ptr;

type BytesCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);

/// Parses one JSON document. Child pointers remain valid until the root is freed.
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_parse(data: *const u8, length: usize) -> *mut Value {
    if data.is_null() || length > isize::MAX as usize { return ptr::null_mut(); }
    let Some(value) = crate::json_parse::parse_first(std::slice::from_raw_parts(data, length)) else { return ptr::null_mut() };
    Box::into_raw(Box::new(value))
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_free(root: *mut Value) {
    if !root.is_null() { drop(Box::from_raw(root)); }
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_kind(node: *const Value) -> i32 {
    match node.as_ref() {
        Some(Value::Null) => 0, Some(Value::Bool(_)) => 1, Some(Value::Number(_)) => 2,
        Some(Value::String(_)) => 3, Some(Value::Array(_)) => 4, Some(Value::Object(_)) => 5, None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_count(node: *const Value) -> usize {
    match node.as_ref() { Some(Value::Array(v)) => v.len(), Some(Value::Object(v)) => v.len(), _ => 0 }
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_item(node: *const Value, index: usize) -> *const Value {
    node.as_ref().and_then(Value::as_array).and_then(|items| items.get(index)).map_or(ptr::null(), |value| value)
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_get(node: *const Value, key: *const u8, length: usize) -> *const Value {
    if key.is_null() || length > isize::MAX as usize { return ptr::null(); }
    let Ok(key) = std::str::from_utf8(std::slice::from_raw_parts(key, length)) else { return ptr::null() };
    node.as_ref().and_then(Value::as_object).and_then(|object| object.get(key)).map_or(ptr::null(), |value| value)
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_keys(node: *const Value, context: *mut c_void, callback: Option<BytesCallback>) -> i32 {
    let Some(callback) = callback else { return 0 };
    let Some(object) = node.as_ref().and_then(Value::as_object) else { return 0 };
    for key in object.keys() { callback(context, key.as_ptr(), key.len()); }
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_string(node: *const Value, context: *mut c_void, callback: Option<BytesCallback>) -> i32 {
    let Some(callback) = callback else { return 0 };
    let Some(value) = node.as_ref().and_then(Value::as_str) else { return 0 };
    callback(context, value.as_ptr(), value.len());
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_bool(node: *const Value) -> i32 {
    match node.as_ref().and_then(Value::as_bool) { Some(true) => 1, Some(false) => 0, None => -1 }
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_double(node: *const Value, result: *mut f64) -> i32 {
    if result.is_null() { return 0; }
    let Some(value) = node.as_ref().and_then(Value::as_f64) else { return 0 };
    *result = value;
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_i64(node: *const Value, result: *mut i64) -> i32 {
    if result.is_null() { return 0; }
    let Some(number) = node.as_ref().and_then(Value::as_number) else { return 0 };
    let value = number.as_i64().or_else(|| number.as_f64().and_then(|value| {
        if value.is_finite() && value.fract() == 0.0 && value >= -9_223_372_036_854_775_808.0 && value < 9_223_372_036_854_775_808.0 { Some(value as i64) } else { None }
    }));
    let Some(value) = value else { return 0 };
    *result = value;
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_u64(node: *const Value, result: *mut u64) -> i32 {
    if result.is_null() { return 0; }
    let Some(number) = node.as_ref().and_then(Value::as_number) else { return 0 };
    let value = number.as_u64().or_else(|| number.as_f64().and_then(|value| {
        if value.is_finite() && value.fract() == 0.0 && value >= 0.0 && value < 18_446_744_073_709_551_616.0 { Some(value as u64) } else { None }
    }));
    let Some(value) = value else { return 0 };
    *result = value;
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accessors_distinguish_missing_null_and_numeric_boundaries() {
        let bytes = br#"{"a":null,"b":[1,1.0,-1,18446744073709551615]}"#;
        let root = unsafe { launchpad_json_parse(bytes.as_ptr(), bytes.len()) };
        assert!(!root.is_null());
        let key = |key: &[u8]| unsafe { launchpad_json_get(root, key.as_ptr(), key.len()) };
        assert_eq!(unsafe { launchpad_json_kind(key(b"a")) }, 0);
        assert!(key(b"missing").is_null());
        let array = key(b"b");
        assert_eq!(unsafe { launchpad_json_count(array) }, 4);
        let mut signed = 0_i64;
        assert_eq!(unsafe { launchpad_json_i64(launchpad_json_item(array, 1), &mut signed) }, 1);
        assert_eq!(signed, 1);
        assert_eq!(unsafe { launchpad_json_i64(launchpad_json_item(array, 3), &mut signed) }, 0);
        let mut unsigned = 0_u64;
        assert_eq!(unsafe { launchpad_json_u64(launchpad_json_item(array, 3), &mut unsigned) }, 1);
        assert_eq!(unsigned, u64::MAX);
        assert_eq!(unsafe { launchpad_json_u64(launchpad_json_item(array, 2), &mut unsigned) }, 0);
        unsafe { launchpad_json_free(root) };
    }
}
