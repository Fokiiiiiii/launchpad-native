use serde_json::Number;
#[cfg(test)] use serde_json::Value;
use std::collections::BTreeMap;
use std::ffi::c_void;

enum Node { Null, Bool(bool), Number(Number), String(String), Array(Vec<usize>), Object(BTreeMap<String, usize>) }
pub struct Builder { nodes: Vec<Node> }

impl Builder {
    fn add(&mut self) -> Option<usize> {
        if self.nodes.len() >= 1_000_000 { return None; }
        let index = self.nodes.len();
        self.nodes.push(Node::Null);
        Some(index)
    }
    
}

#[no_mangle]
pub extern "C" fn launchpad_json_builder_new() -> *mut Builder { Box::into_raw(Box::new(Builder { nodes: vec![Node::Null] })) }
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_free(builder: *mut Builder) { if !builder.is_null() { drop(Box::from_raw(builder)); } }

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_container(builder: *mut Builder, index: usize, kind: i32) -> i32 {
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 };
    match (&mut *node, kind) {
        (Node::Null, 4) => *node = Node::Array(Vec::new()),
        (Node::Null, 5) => *node = Node::Object(BTreeMap::new()),
        (Node::Array(_), 4) | (Node::Object(_), 5) => {},
        _ => return 0,
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_key(builder: *mut Builder, parent: usize, key: *const u8, length: usize) -> usize {
    if key.is_null() || length > isize::MAX as usize { return usize::MAX; }
    let Some(builder) = builder.as_mut() else { return usize::MAX };
    let Ok(key) = std::str::from_utf8(std::slice::from_raw_parts(key, length)) else { return usize::MAX };
    let Some(Node::Object(object)) = builder.nodes.get(parent) else { return usize::MAX };
    if let Some(index) = object.get(key) { return *index; }
    let Some(index) = builder.add() else { return usize::MAX };
    let Node::Object(object) = &mut builder.nodes[parent] else { unreachable!() };
    object.insert(key.to_owned(), index);
    index
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_append(builder: *mut Builder, parent: usize) -> usize {
    let Some(builder) = builder.as_mut() else { return usize::MAX };
    if !matches!(builder.nodes.get(parent), Some(Node::Array(_))) { return usize::MAX; }
    let Some(index) = builder.add() else { return usize::MAX };
    let Node::Array(items) = &mut builder.nodes[parent] else { unreachable!() };
    items.push(index);
    index
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_null(builder: *mut Builder, index: usize) -> i32 {
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::Null; 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_bool(builder: *mut Builder, index: usize, value: i32) -> i32 {
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::Bool(value != 0); 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_i64(builder: *mut Builder, index: usize, value: i64) -> i32 {
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::Number(value.into()); 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_u64(builder: *mut Builder, index: usize, value: u64) -> i32 {
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::Number(value.into()); 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_double(builder: *mut Builder, index: usize, value: f64) -> i32 {
    let Some(number) = Number::from_f64(value) else { return 0 };
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::Number(number); 1
}
#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_string(builder: *mut Builder, index: usize, bytes: *const u8, length: usize) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Ok(value) = std::str::from_utf8(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    let Some(node) = builder.as_mut().and_then(|b| b.nodes.get_mut(index)) else { return 0 }; *node = Node::String(value.into()); 1
}
struct NodeView<'a> { builder: &'a Builder, index: usize, depth: usize }

impl serde::Serialize for NodeView<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{Error, SerializeMap, SerializeSeq};
        if self.depth > 128 { return Err(S::Error::custom("JSON nesting limit")); }
        let node = self.builder.nodes.get(self.index).ok_or_else(|| S::Error::custom("invalid JSON node"))?;
        match node {
            Node::Null => serializer.serialize_unit(),
            Node::Bool(value) => serializer.serialize_bool(*value),
            Node::Number(value) => serde::Serialize::serialize(value, serializer),
            Node::String(value) => serializer.serialize_str(value),
            Node::Array(items) => {
                let mut sequence = serializer.serialize_seq(Some(items.len()))?;
                for &index in items {
                    sequence.serialize_element(&NodeView { builder: self.builder, index, depth: self.depth + 1 })?;
                }
                sequence.end()
            }
            Node::Object(items) => {
                let mut object = serializer.serialize_map(Some(items.len()))?;
                for (key, &index) in items {
                    object.serialize_entry(key, &NodeView { builder: self.builder, index, depth: self.depth + 1 })?;
                }
                object.end()
            }
        }
    }
}

unsafe fn finish(builder: *const Builder, pretty: bool, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>) -> i32 {
    let Some(callback) = callback else { return 0 };
    let Some(builder) = builder.as_ref() else { return 0 };
    let value = NodeView { builder, index: 0, depth: 0 };
    let result = if pretty { serde_json::to_vec_pretty(&value) } else { serde_json::to_vec(&value) };
    let Ok(data) = result else { return 0 };
    callback(context, data.as_ptr(), data.len());
    1
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_finish(builder: *const Builder, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>) -> i32 {
    finish(builder, false, context, callback)
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_json_builder_finish_pretty(builder: *const Builder, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>) -> i32 {
    finish(builder, true, context, callback)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn builder_preserves_null_unicode_and_integer_precision() {
        unsafe extern "C" fn collect(context: *mut c_void, data: *const u8, length: usize) {
            let out = &mut *(context as *mut Vec<u8>);
            out.extend_from_slice(std::slice::from_raw_parts(data, length));
        }
        unsafe {
            let b = launchpad_json_builder_new();
            assert_eq!(launchpad_json_builder_container(b, 0, 5), 1);
            let key = "名前".as_bytes();
            let child = launchpad_json_builder_key(b, 0, key.as_ptr(), key.len());
            assert_eq!(launchpad_json_builder_u64(b, child, u64::MAX), 1);
            let nil_key = b"nil";
            let nil = launchpad_json_builder_key(b, 0, nil_key.as_ptr(), nil_key.len());
            assert_eq!(launchpad_json_builder_null(b, nil), 1);
            let mut result = Vec::new();
            assert_eq!(launchpad_json_builder_finish(b, (&mut result as *mut Vec<u8>).cast(), Some(collect)), 1);
            let value: Value = serde_json::from_slice(&result).unwrap();
            assert_eq!(value["名前"].as_u64(), Some(u64::MAX));
            assert!(value["nil"].is_null());
            launchpad_json_builder_free(b);
        }
    }
}
