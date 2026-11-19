use serde_json::{Map, Value};
use std::ffi::c_void;

type Callback = unsafe extern "C" fn(*mut c_void, *const u8, usize);
const REQUIRED: [&str; 7] = ["bundleIdentifier", "bundleURL", "displayName", "originalDisplayName", "sourceID", "iconCacheKey", "value"];
const OPTIONAL: [&str; 4] = ["executableURL", "bundleVersion", "teamIdentifier", "category"];
const FLAGS: [&str; 5] = ["isSystemProtected", "isBackgroundOnly", "isMenuBarApp", "canLaunch", "canOpenNewInstance"];

struct Reader<'a> { data: &'a [u8] }
impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let (head, tail) = self.data.split_at_checked(count)?;
        self.data = tail;
        Some(head)
    }
    fn u32(&mut self) -> Option<u32> { Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?)) }
    fn string(&mut self, optional: bool) -> Option<Option<&'a str>> {
        let size = self.u32()?;
        if size == u32::MAX { return if optional { Some(None) } else { None }; }
        Some(Some(std::str::from_utf8(self.take(size as usize)?).ok()?))
    }
}
fn put_string(out: &mut Vec<u8>, value: Option<&str>) -> Option<()> {
    match value {
        None => out.extend_from_slice(&u32::MAX.to_le_bytes()),
        Some(value) => {
            let length = u32::try_from(value.len()).ok()?;
            if length == u32::MAX { return None; }
            out.extend_from_slice(&length.to_le_bytes());
            out.extend_from_slice(value.as_bytes());
        }
    }
    Some(())
}
struct RecordView<'a> { required: [&'a str; 7], optional: [Option<&'a str>; 4], flags: [bool; 5], date: f64 }

fn read_record<'a>(input: &mut Reader<'a>) -> Option<RecordView<'a>> {
    let mut required = [""; 7];
    for value in &mut required { *value = input.string(false)??; }
    let mut optional = [None; 4];
    for value in &mut optional { *value = input.string(true)?; }
    let mut flags = [false; 5];
    for value in &mut flags {
        let byte = *input.take(1)?.first()?;
        if byte > 1 { return None; }
        *value = byte == 1;
    }
    let date = f64::from_le_bytes(input.take(8)?.try_into().ok()?);
    if !date.is_finite() { return None; }
    Some(RecordView { required, optional, flags, date })
}

struct IdentityView<'a>(&'a str);
impl serde::Serialize for IdentityView<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut object = serializer.serialize_map(Some(1))?;
        object.serialize_entry("value", self.0)?;
        object.end()
    }
}
impl serde::Serialize for RecordView<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut object = serializer.serialize_map(None)?;
        for (name, value) in REQUIRED.iter().zip(self.required) {
            if *name == "value" { object.serialize_entry("id", &IdentityView(value))?; }
            else { object.serialize_entry(name, value)?; }
        }
        for (name, value) in OPTIONAL.iter().zip(self.optional) {
            if let Some(value) = value { object.serialize_entry(name, value)?; }
        }
        for (name, value) in FLAGS.iter().zip(self.flags) { object.serialize_entry(name, &value)?; }
        object.serialize_entry("lastSeenModificationDate", &self.date)?;
        object.end()
    }
}

struct RecordsView<'a> { bytes: &'a [u8], count: usize }
impl serde::Serialize for RecordsView<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{Error, SerializeSeq};
        let mut input = Reader { data: self.bytes };
        let mut sequence = serializer.serialize_seq(Some(self.count))?;
        for _ in 0..self.count {
            let record = read_record(&mut input).ok_or_else(|| S::Error::custom("invalid catalog record"))?;
            sequence.serialize_element(&record)?;
        }
        if !input.data.is_empty() { return Err(S::Error::custom("trailing catalog data")); }
        sequence.end()
    }
}

struct SnapshotView<'a> { bytes: &'a [u8] }
impl serde::Serialize for SnapshotView<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{Error, SerializeMap};
        let mut input = Reader { data: self.bytes };
        let count = input.u32().ok_or_else(|| S::Error::custom("invalid catalog count"))? as usize;
        if count > input.data.len() / 57 { return Err(S::Error::custom("invalid catalog count")); }
        let mut object = serializer.serialize_map(Some(2))?;
        object.serialize_entry("version", &1)?;
        object.serialize_entry("records", &RecordsView { bytes: input.data, count })?;
        object.end()
    }
}

fn encode(bytes: &[u8]) -> Option<Vec<u8>> {
    serde_json::to_vec(&SnapshotView { bytes }).ok()
}
fn append_record(record: &Map<String, Value>, out: &mut Vec<u8>) -> Option<()> {
    for name in REQUIRED {
        let value = if name == "value" { record.get("id")?.as_object()?.get("value")?.as_str()? } else { record.get(name)?.as_str()? };
        put_string(out, Some(value))?;
    }
    for name in OPTIONAL {
        match record.get(name) {
            None | Some(Value::Null) => put_string(out, None)?,
            Some(value) => put_string(out, Some(value.as_str()?))?,
        }
    }
    for name in FLAGS { out.push(u8::from(record.get(name)?.as_bool()?)); }
    let date = record.get("lastSeenModificationDate")?.as_f64()?;
    if !date.is_finite() { return None; }
    out.extend_from_slice(&date.to_le_bytes());
    Some(())
}

struct Records(Vec<u8>);
impl<'de> serde::Deserialize<'de> for Records {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct RecordsVisitor;
        impl<'de> serde::de::Visitor<'de> for RecordsVisitor {
            type Value = Records;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result { formatter.write_str("a catalog record array") }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut sequence: A) -> Result<Self::Value, A::Error> {
                use serde::de::Error;
                let mut out = vec![0; 4];
                let mut count = 0_u32;
                while let Some(value) = sequence.next_element::<crate::json_parse::FirstValue>()? {
                    let record = value.0.as_object().ok_or_else(|| A::Error::custom("invalid catalog record"))?;
                    append_record(record, &mut out).ok_or_else(|| A::Error::custom("invalid catalog record"))?;
                    count = count.checked_add(1).ok_or_else(|| A::Error::custom("too many records"))?;
                }
                out[..4].copy_from_slice(&count.to_le_bytes());
                Ok(Records(out))
            }
        }
        deserializer.deserialize_seq(RecordsVisitor)
    }
}

struct Snapshot(Records);
impl<'de> serde::Deserialize<'de> for Snapshot {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct SnapshotVisitor;
        impl<'de> serde::de::Visitor<'de> for SnapshotVisitor {
            type Value = Snapshot;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result { formatter.write_str("a catalog snapshot") }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut object: A) -> Result<Self::Value, A::Error> {
                use serde::de::Error;
                let mut version = None;
                let mut records = None;
                while let Some(key) = object.next_key::<String>()? {
                    match key.as_str() {
                        "version" if version.is_none() => {
                            let value = object.next_value::<crate::json_parse::FirstValue>()?;
                            version = Some(value.0.as_f64().ok_or_else(|| A::Error::custom("invalid version"))?);
                        }
                        "records" if records.is_none() => { records = Some(object.next_value::<Records>()?); }
                        _ => { object.next_value::<serde::de::IgnoredAny>()?; }
                    }
                }
                if version != Some(1.0) { return Err(A::Error::custom("invalid version")); }
                Ok(Snapshot(records.ok_or_else(|| A::Error::missing_field("records"))?))
            }
        }
        deserializer.deserialize_map(SnapshotVisitor)
    }
}

fn decode(bytes: &[u8]) -> Option<Vec<u8>> {
    let text = crate::json_parse::text(bytes)?;
    let snapshot: Snapshot = serde_json::from_str(&text).ok()?;
    Some(snapshot.0.0)
}

/// Converts a length-delimited record stream to the existing snapshot JSON.
#[no_mangle]
pub unsafe extern "C" fn launchpad_catalog_encode(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<Callback>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(output) = encode(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, output.as_ptr(), output.len());
    1
}

/// Validates snapshot JSON and converts it to a length-delimited record stream.
#[no_mangle]
pub unsafe extern "C" fn launchpad_catalog_decode(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<Callback>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(output) = decode(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, output.as_ptr(), output.len());
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_roundtrip_and_rejects_malformed_data() {
        let mut input = Vec::new();
        input.extend_from_slice(&1_u32.to_le_bytes());
        for value in ["com.example", "file:///tmp/A.app", "A", "A", "source", "key", "stable-id"] { put_string(&mut input, Some(value)).unwrap(); }
        for _ in 0..4 { put_string(&mut input, None).unwrap(); }
        input.extend_from_slice(&[false as u8, 0, 0, 1, 1]);
        input.extend_from_slice(&123.25_f64.to_le_bytes());
        let json = encode(&input).unwrap();
        assert_eq!(decode(&json), Some(input.clone()));
        let json_text = std::str::from_utf8(&json).unwrap();
        let mut utf16 = Vec::new();
        for value in json_text.encode_utf16() { utf16.extend_from_slice(&value.to_le_bytes()); }
        assert_eq!(decode(&utf16), Some(input));
        let duplicate = json_text.replacen("\"bundleIdentifier\":\"com.example\"", "\"bundleIdentifier\":\"first\",\"bundleIdentifier\":\"com.example\"", 1);
        let decoded = decode(duplicate.as_bytes()).unwrap();
        let mut reader = Reader { data: &decoded };
        assert_eq!(reader.u32(), Some(1));
        assert_eq!(reader.string(false), Some(Some("first")));
        assert!(decode(br#"{"version":1.0,"records":[]}"#).is_some());
        assert!(decode(br#"{"version":2,"records":[]}"#).is_none());
        assert!(decode(br#"{"version":1,"records":[{}]}"#).is_none());
        assert!(encode(&[1, 0, 0, 0]).is_none());
    }
}
