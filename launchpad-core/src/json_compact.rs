use serde::de::{DeserializeSeed, Error, IgnoredAny, MapAccess, SeqAccess, Visitor};
use std::collections::HashSet;
use std::ffi::c_void;
use std::fmt;
use std::ptr;

type BytesCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);

fn put32(out: &mut Vec<u8>, value: u32) { out.extend_from_slice(&value.to_le_bytes()); }
fn patch32(out: &mut [u8], offset: usize, value: u32) { out[offset..offset + 4].copy_from_slice(&value.to_le_bytes()); }
fn begin(out: &mut Vec<u8>, tag: u8) -> usize { let start = out.len(); out.push(tag); put32(out, 0); start }
fn finish<E: Error>(out: &mut [u8], start: usize) -> Result<(), E> {
    let length = u32::try_from(out.len() - start - 5).map_err(|_| E::custom("JSON value too large"))?;
    patch32(out, start + 1, length);
    Ok(())
}
fn offset<E: Error>(out: &[u8], start: usize) -> Result<u32, E> {
    u32::try_from(out.len() - start).map_err(|_| E::custom("JSON value too large"))
}

struct Seed<'a> { out: &'a mut Vec<u8> }
impl<'de> DeserializeSeed<'de> for Seed<'_> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, deserializer: D) -> Result<(), D::Error> {
        deserializer.deserialize_any(CompactVisitor { out: self.out })
    }
}
struct CompactVisitor<'a> { out: &'a mut Vec<u8> }
impl<'de> Visitor<'de> for CompactVisitor<'_> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("a JSON value") }
    fn visit_unit<E: Error>(self) -> Result<(), E> { let start = begin(self.out, 0); finish(self.out, start) }
    fn visit_none<E: Error>(self) -> Result<(), E> { self.visit_unit() }
    fn visit_bool<E: Error>(self, value: bool) -> Result<(), E> { let start = begin(self.out, 1); self.out.push(u8::from(value)); finish(self.out, start) }
    fn visit_i64<E: Error>(self, value: i64) -> Result<(), E> { let start = begin(self.out, 2); self.out.extend_from_slice(&value.to_le_bytes()); finish(self.out, start) }
    fn visit_u64<E: Error>(self, value: u64) -> Result<(), E> { let start = begin(self.out, 3); self.out.extend_from_slice(&value.to_le_bytes()); finish(self.out, start) }
    fn visit_f64<E: Error>(self, value: f64) -> Result<(), E> {
        if !value.is_finite() { return Err(E::custom("invalid number")); }
        let start = begin(self.out, 4); self.out.extend_from_slice(&value.to_le_bytes()); finish(self.out, start)
    }
    fn visit_str<E: Error>(self, value: &str) -> Result<(), E> { let start = begin(self.out, 5); self.out.extend_from_slice(value.as_bytes()); finish(self.out, start) }
    fn visit_string<E: Error>(self, value: String) -> Result<(), E> { self.visit_str(&value) }
    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<(), A::Error> {
        let start = begin(self.out, 6);
        put32(self.out, 0);
        let mut offsets = Vec::new();
        loop {
            let position = offset::<A::Error>(self.out, start)?;
            match sequence.next_element_seed(Seed { out: self.out })? {
                Some(()) => offsets.push(position),
                None => break,
            }
        }
        let count = u32::try_from(offsets.len()).map_err(|_| A::Error::custom("too many JSON elements"))?;
        patch32(self.out, start + 5, count);
        for position in offsets { put32(self.out, position); }
        finish(self.out, start)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let start = begin(self.out, 7);
        put32(self.out, 0);
        let mut seen = HashSet::new();
        let mut offsets = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            if !seen.insert(key.clone()) { map.next_value::<IgnoredAny>()?; continue; }
            let position = offset::<A::Error>(self.out, start)?;
            let length = u32::try_from(key.len()).map_err(|_| A::Error::custom("JSON key too large"))?;
            put32(self.out, length);
            self.out.extend_from_slice(key.as_bytes());
            map.next_value_seed(Seed { out: self.out })?;
            offsets.push((key, position));
        }
        offsets.sort_unstable_by(|left, right| left.0.as_bytes().cmp(right.0.as_bytes()));
        let count = u32::try_from(offsets.len()).map_err(|_| A::Error::custom("too many JSON keys"))?;
        patch32(self.out, start + 5, count);
        for (_, position) in offsets { put32(self.out, position); }
        finish(self.out, start)
    }
}

fn compact(bytes: &[u8]) -> Option<Vec<u8>> {
    let text = crate::json_parse::text(bytes)?;
    let mut deserializer = serde_json::Deserializer::from_str(&text);
    let mut out = Vec::new();
    Seed { out: &mut out }.deserialize(&mut deserializer).ok()?;
    deserializer.end().ok()?;
    Some(out)
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_parse(data: *const u8, length: usize) -> *mut u8 {
    if data.is_null() || length > isize::MAX as usize { return ptr::null_mut(); }
    let Some(value) = compact(std::slice::from_raw_parts(data, length)) else { return ptr::null_mut() };
    Box::into_raw(value.into_boxed_slice()) as *mut u8
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_free(root: *mut u8) {
    if root.is_null() { return; }
    let length = u32::from_le(ptr::read_unaligned(root.add(1).cast::<u32>())) as usize + 5;
    drop(Box::from_raw(ptr::slice_from_raw_parts_mut(root, length)));
}

unsafe fn payload<'a>(node: *const u8) -> Option<&'a [u8]> {
    if node.is_null() { return None; }
    let length = u32::from_le(ptr::read_unaligned(node.add(1).cast::<u32>())) as usize;
    Some(std::slice::from_raw_parts(node.add(5), length))
}
fn read32(bytes: &[u8], start: usize) -> Option<usize> {
    Some(u32::from_le_bytes(bytes.get(start..start.checked_add(4)?)?.try_into().ok()?) as usize)
}
fn indexed(bytes: &[u8], index: usize) -> Option<usize> {
    let count = read32(bytes, 0)?;
    if index >= count { return None; }
    let table = bytes.len().checked_sub(count.checked_mul(4)?)?;
    if table < 4 { return None; }
    let value = read32(bytes, table + index * 4)?.checked_sub(5)?;
    if value < 4 || value >= table { return None; }
    Some(value)
}
fn child_at(bytes: &[u8], offset: usize) -> Option<*const u8> {
    let length = read32(bytes, offset.checked_add(1)?)?;
    bytes.get(offset..offset.checked_add(5)?.checked_add(length)?)?;
    Some(unsafe { bytes.as_ptr().add(offset) })
}
fn pair_at(bytes: &[u8], index: usize) -> Option<(&[u8], *const u8)> {
    let position = indexed(bytes, index)?;
    let length = read32(bytes, position)?;
    let start = position.checked_add(4)?;
    let end = start.checked_add(length)?;
    let key = bytes.get(start..end)?;
    Some((key, child_at(bytes, end)?))
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_kind(node: *const u8) -> i32 {
    if node.is_null() { return -1; }
    match *node { 0 => 0, 1 => 1, 2..=4 => 2, 5 => 3, 6 => 4, 7 => 5, _ => -1 }
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_count(node: *const u8) -> usize {
    if node.is_null() || !matches!(*node, 6 | 7) { return 0; }
    payload(node).and_then(|bytes| read32(bytes, 0)).unwrap_or(0)
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_item(node: *const u8, index: usize) -> *const u8 {
    if node.is_null() || *node != 6 { return ptr::null(); }
    payload(node).and_then(|bytes| indexed(bytes, index).and_then(|position| child_at(bytes, position))).unwrap_or(ptr::null())
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_get(node: *const u8, key: *const u8, length: usize) -> *const u8 {
    if node.is_null() || *node != 7 || key.is_null() || length > isize::MAX as usize { return ptr::null(); }
    let Some(bytes) = payload(node) else { return ptr::null() };
    let key = std::slice::from_raw_parts(key, length);
    let mut low = 0;
    let mut high = read32(bytes, 0).unwrap_or(0);
    while low < high {
        let mid = low + (high - low) / 2;
        let Some((candidate, value)) = pair_at(bytes, mid) else { return ptr::null() };
        match candidate.cmp(key) {
            std::cmp::Ordering::Less => low = mid + 1,
            std::cmp::Ordering::Greater => high = mid,
            std::cmp::Ordering::Equal => return value,
        }
    }
    ptr::null()
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_keys(node: *const u8, context: *mut c_void, callback: Option<BytesCallback>) -> i32 {
    let Some(callback) = callback else { return 0 };
    if node.is_null() || *node != 7 { return 0; }
    let Some(bytes) = payload(node) else { return 0 };
    let Some(count) = read32(bytes, 0) else { return 0 };
    for index in 0..count {
        let Some((key, _)) = pair_at(bytes, index) else { return 0 };
        callback(context, key.as_ptr(), key.len());
    }
    1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_string(node: *const u8, context: *mut c_void, callback: Option<BytesCallback>) -> i32 {
    let Some(callback) = callback else { return 0 };
    if node.is_null() || *node != 5 { return 0; }
    let Some(bytes) = payload(node) else { return 0 };
    callback(context, bytes.as_ptr(), bytes.len());
    1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_bool(node: *const u8) -> i32 {
    if node.is_null() || *node != 1 { return -1; }
    match payload(node).and_then(|bytes| bytes.first()) { Some(0) => 0, Some(1) => 1, _ => -1 }
}
fn integer_or_float(node: *const u8) -> Option<(u8, [u8; 8])> {
    unsafe {
        if node.is_null() || !matches!(*node, 2..=4) { return None; }
        Some((*node, payload(node)?.try_into().ok()?))
    }
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_double(node: *const u8, result: *mut f64) -> i32 {
    if result.is_null() { return 0; }
    let Some((kind, bytes)) = integer_or_float(node) else { return 0 };
    *result = match kind { 2 => i64::from_le_bytes(bytes) as f64, 3 => u64::from_le_bytes(bytes) as f64, 4 => f64::from_le_bytes(bytes), _ => return 0 };
    1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_i64(node: *const u8, result: *mut i64) -> i32 {
    if result.is_null() { return 0; }
    let Some((kind, bytes)) = integer_or_float(node) else { return 0 };
    let value = match kind {
        2 => Some(i64::from_le_bytes(bytes)),
        3 => i64::try_from(u64::from_le_bytes(bytes)).ok(),
        4 => { let v = f64::from_le_bytes(bytes); if v.is_finite() && v.fract() == 0.0 && v >= -9_223_372_036_854_775_808.0 && v < 9_223_372_036_854_775_808.0 { Some(v as i64) } else { None } },
        _ => None,
    };
    let Some(value) = value else { return 0 }; *result = value; 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_compact_u64(node: *const u8, result: *mut u64) -> i32 {
    if result.is_null() { return 0; }
    let Some((kind, bytes)) = integer_or_float(node) else { return 0 };
    let value = match kind {
        2 => u64::try_from(i64::from_le_bytes(bytes)).ok(),
        3 => Some(u64::from_le_bytes(bytes)),
        4 => { let v = f64::from_le_bytes(bytes); if v.is_finite() && v.fract() == 0.0 && v >= 0.0 && v < 18_446_744_073_709_551_616.0 { Some(v as u64) } else { None } },
        _ => None,
    };
    let Some(value) = value else { return 0 }; *result = value; 1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compact_tree_supports_arrays_objects_unicode_and_duplicate_keys() {
        let json = "{\"z\":[1,2.0,-3,18446744073709551615],\"名前\":\"値\",\"z\":[99],\"nil\":null}";
        unsafe {
            let root = launchpad_compact_parse(json.as_ptr(), json.len());
            assert!(!root.is_null());
            assert_eq!(launchpad_compact_kind(root), 5);
            assert_eq!(launchpad_compact_count(root), 3);
            let array = launchpad_compact_get(root, b"z".as_ptr(), 1);
            assert_eq!(launchpad_compact_count(array), 4);
            let mut signed = 0;
            assert_eq!(launchpad_compact_i64(launchpad_compact_item(array, 1), &mut signed), 1);
            assert_eq!(signed, 2);
            let mut unsigned = 0;
            assert_eq!(launchpad_compact_u64(launchpad_compact_item(array, 3), &mut unsigned), 1);
            assert_eq!(unsigned, u64::MAX);
            let key = "名前".as_bytes();
            assert_eq!(launchpad_compact_kind(launchpad_compact_get(root, key.as_ptr(), key.len())), 3);
            assert_eq!(launchpad_compact_kind(launchpad_compact_get(root, b"nil".as_ptr(), 3)), 0);
            assert!(launchpad_compact_get(root, b"missing".as_ptr(), 7).is_null());
            launchpad_compact_free(root);
        }
    }

    #[test]
    fn compact_matches_reference_tree_across_nested_values() {
        unsafe extern "C" fn collect(context: *mut c_void, bytes: *const u8, length: usize) {
            let output = &mut *(context as *mut Vec<u8>);
            output.extend_from_slice(std::slice::from_raw_parts(bytes, length));
        }
        unsafe fn compare(reference: *const serde_json::Value, compact: *const u8) {
            let expected = crate::json::launchpad_json_kind(reference);
            assert_eq!(launchpad_compact_kind(compact), expected);
            match expected {
                0 => {},
                1 => assert_eq!(launchpad_compact_bool(compact), crate::json::launchpad_json_bool(reference)),
                2 => {
                    let mut left = 0_f64; let mut right = 0_f64;
                    assert_eq!(launchpad_compact_double(compact, &mut left), crate::json::launchpad_json_double(reference, &mut right));
                    assert_eq!(left.to_bits(), right.to_bits());
                    let mut left = 0_i64; let mut right = 0_i64;
                    assert_eq!(launchpad_compact_i64(compact, &mut left), crate::json::launchpad_json_i64(reference, &mut right));
                    assert_eq!(left, right);
                    let mut left = 0_u64; let mut right = 0_u64;
                    assert_eq!(launchpad_compact_u64(compact, &mut left), crate::json::launchpad_json_u64(reference, &mut right));
                    assert_eq!(left, right);
                }
                3 => {
                    let mut left = Vec::new(); let mut right = Vec::new();
                    assert_eq!(launchpad_compact_string(compact, (&mut left as *mut Vec<u8>).cast(), Some(collect)), 1);
                    assert_eq!(crate::json::launchpad_json_string(reference, (&mut right as *mut Vec<u8>).cast(), Some(collect)), 1);
                    assert_eq!(left, right);
                }
                4 => {
                    let count = crate::json::launchpad_json_count(reference);
                    assert_eq!(launchpad_compact_count(compact), count);
                    for index in 0..count { compare(crate::json::launchpad_json_item(reference, index), launchpad_compact_item(compact, index)); }
                }
                5 => {
                    let object = (*reference).as_object().unwrap();
                    assert_eq!(launchpad_compact_count(compact), object.len());
                    for (key, value) in object {
                        let child = launchpad_compact_get(compact, key.as_ptr(), key.len());
                        assert!(!child.is_null());
                        compare(value, child);
                    }
                }
                _ => panic!("unexpected kind"),
            }
        }
        for bytes in [b"-0".as_slice(), b"-0.0", b"1e0", b"-9223372036854775808", b"9223372036854775807", b"18446744073709551615", b"1.5"] {
            unsafe {
                let reference = crate::json::launchpad_json_parse(bytes.as_ptr(), bytes.len());
                let compact = launchpad_compact_parse(bytes.as_ptr(), bytes.len());
                assert!(!reference.is_null() && !compact.is_null());
                compare(reference, compact);
                crate::json::launchpad_json_free(reference);
                launchpad_compact_free(compact);
            }
        }
        let mut seed = 7_u64;
        for iteration in 0..300 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let values: Vec<serde_json::Value> = (0..(seed as usize % 50)).map(|index| {
                serde_json::json!({"名前": format!("文字\0{iteration}-{index}"), "number": (seed ^ index as u64), "nil": null, "nested": [true, false, -3, 2.5]})
            }).collect();
            let bytes = serde_json::to_vec(&serde_json::json!({"items": values, "empty": {}, "text": "é 👨‍👩‍👧"})).unwrap();
            unsafe {
                let reference = crate::json::launchpad_json_parse(bytes.as_ptr(), bytes.len());
                let compact = launchpad_compact_parse(bytes.as_ptr(), bytes.len());
                assert!(!reference.is_null() && !compact.is_null());
                compare(reference, compact);
                crate::json::launchpad_json_free(reference);
                launchpad_compact_free(compact);
            }
        }
    }
}
