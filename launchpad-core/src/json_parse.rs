use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::borrow::Cow;
use std::fmt;

pub(crate) struct FirstValue(pub(crate) Value);
impl<'de> Deserialize<'de> for FirstValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ValueVisitor;
        impl<'de> Visitor<'de> for ValueVisitor {
            type Value = FirstValue;
            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result { formatter.write_str("a JSON value") }
            fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<Self::Value, E> { Ok(FirstValue(Value::Bool(value))) }
            fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Self::Value, E> { Ok(FirstValue(Value::Number(value.into()))) }
            fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Self::Value, E> { Ok(FirstValue(Value::Number(value.into()))) }
            fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<Self::Value, E> {
                Number::from_f64(value).map(|n| FirstValue(Value::Number(n))).ok_or_else(|| E::custom("invalid number"))
            }
            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Self::Value, E> { Ok(FirstValue(Value::String(value.into()))) }
            fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Self::Value, E> { Ok(FirstValue(Value::String(value))) }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> { Ok(FirstValue(Value::Null)) }
            fn visit_none<E: serde::de::Error>(self) -> Result<Self::Value, E> { Ok(FirstValue(Value::Null)) }
            fn visit_seq<A: SeqAccess<'de>>(self, mut access: A) -> Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = access.next_element::<FirstValue>()? { values.push(value.0); }
                Ok(FirstValue(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<Self::Value, A::Error> {
                let mut values = Map::new();
                while let Some(key) = access.next_key::<String>()? {
                    let value = access.next_value::<FirstValue>()?;
                    values.entry(key).or_insert(value.0);
                }
                Ok(FirstValue(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(ValueVisitor)
    }
}

pub(crate) fn text(bytes: &[u8]) -> Option<Cow<'_, str>> {
    let (bytes, encoding) = if bytes.starts_with(&[0, 0, 0xfe, 0xff]) { (&bytes[4..], 4) }
    else if bytes.starts_with(&[0xff, 0xfe, 0, 0]) { (&bytes[4..], 5) }
    else if bytes.starts_with(&[0xfe, 0xff]) { (&bytes[2..], 2) }
    else if bytes.starts_with(&[0xff, 0xfe]) { (&bytes[2..], 3) }
    else if bytes.starts_with(&[0xef, 0xbb, 0xbf]) { (&bytes[3..], 0) }
    else if bytes.len() >= 4 && bytes[0..3] == [0, 0, 0] { (bytes, 4) }
    else if bytes.len() >= 4 && bytes[1..4] == [0, 0, 0] { (bytes, 5) }
    else if bytes.len() >= 4 && bytes[0] == 0 && bytes[2] == 0 { (bytes, 2) }
    else if bytes.len() >= 4 && bytes[1] == 0 && bytes[3] == 0 { (bytes, 3) }
    else { (bytes, 0) };
    match encoding {
        0 => Some(Cow::Borrowed(std::str::from_utf8(bytes).ok()?)),
        2 | 3 => {
            if bytes.len() % 2 != 0 { return None; }
            let units: Vec<u16> = bytes.chunks_exact(2).map(|v| if encoding == 2 { u16::from_be_bytes([v[0], v[1]]) } else { u16::from_le_bytes([v[0], v[1]]) }).collect();
            Some(Cow::Owned(String::from_utf16(&units).ok()?))
        }
        4 | 5 => {
            if bytes.len() % 4 != 0 { return None; }
            let mut result = String::new();
            for chunk in bytes.chunks_exact(4) {
                let value = [chunk[0], chunk[1], chunk[2], chunk[3]];
                result.push(char::from_u32(if encoding == 4 { u32::from_be_bytes(value) } else { u32::from_le_bytes(value) })?);
            }
            Some(Cow::Owned(result))
        }
        _ => None,
    }
}

pub(crate) fn parse_first(bytes: &[u8]) -> Option<Value> {
    let text = text(bytes)?;
    serde_json::from_str::<FirstValue>(&text).ok().map(|value| value.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_utf_encodings_and_keeps_the_first_duplicate_key() {
        let text = "{\"x\":1,\"x\":2,\"名前\":\"値\"}";
        let mut cases = vec![text.as_bytes().to_vec(), [vec![0xef,0xbb,0xbf], text.as_bytes().to_vec()].concat()];
        for big in [false, true] {
            let mut utf16 = Vec::new();
            let mut utf32 = Vec::new();
            for value in text.encode_utf16() { utf16.extend_from_slice(&if big { value.to_be_bytes() } else { value.to_le_bytes() }); }
            for value in text.chars().map(u32::from) { utf32.extend_from_slice(&if big { value.to_be_bytes() } else { value.to_le_bytes() }); }
            let bom16 = if big { vec![0xfe, 0xff] } else { vec![0xff, 0xfe] };
            let bom32 = if big { vec![0, 0, 0xfe, 0xff] } else { vec![0xff, 0xfe, 0, 0] };
            cases.push([bom16, utf16.clone()].concat());
            cases.push([bom32, utf32.clone()].concat());
            cases.push(utf16);
            cases.push(utf32);
        }
        for bytes in cases {
            let parsed = parse_first(&bytes).unwrap();
            assert_eq!(parsed["x"], 1);
            assert_eq!(parsed["名前"], "値");
        }
    }
}
