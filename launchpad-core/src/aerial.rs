use serde::de::{DeserializeSeed, Error, MapAccess, SeqAccess, Visitor};
use std::ffi::c_void;
use std::fmt;

struct Assets<'a>(&'a mut Vec<u8>);
impl<'de> DeserializeSeed<'de> for Assets<'_> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, deserializer: D) -> Result<(), D::Error> {
        deserializer.deserialize_seq(AssetVisitor(self.0))
    }
}

struct AssetVisitor<'a>(&'a mut Vec<u8>);
impl<'de> Visitor<'de> for AssetVisitor<'_> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("an array of asset objects") }
    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<(), A::Error> {
        self.0.push(b'[');
        let mut first = true;
        while let Some(asset) = sequence.next_element::<ProjectedAsset>()? {
            if !first { self.0.push(b','); }
            first = false;
            serde_json::to_writer(&mut *self.0, &asset.0).map_err(A::Error::custom)?;
        }
        self.0.push(b']');
        Ok(())
    }
}



struct Validate;
impl<'de> serde::Deserialize<'de> for Validate {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct VisitorImpl;
        impl<'de> Visitor<'de> for VisitorImpl {
            type Value = Validate;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("a valid JSON value") }
            fn visit_bool<E: Error>(self, _: bool) -> Result<Validate, E> { Ok(Validate) }
            fn visit_i64<E: Error>(self, _: i64) -> Result<Validate, E> { Ok(Validate) }
            fn visit_u64<E: Error>(self, _: u64) -> Result<Validate, E> { Ok(Validate) }
            fn visit_f64<E: Error>(self, _: f64) -> Result<Validate, E> { Ok(Validate) }
            fn visit_str<E: Error>(self, _: &str) -> Result<Validate, E> { Ok(Validate) }
            fn visit_string<E: Error>(self, _: String) -> Result<Validate, E> { Ok(Validate) }
            fn visit_unit<E: Error>(self) -> Result<Validate, E> { Ok(Validate) }
            fn visit_none<E: Error>(self) -> Result<Validate, E> { Ok(Validate) }
            fn visit_seq<A: SeqAccess<'de>>(self, mut values: A) -> Result<Validate, A::Error> {
                while values.next_element::<Validate>()?.is_some() {}
                Ok(Validate)
            }
            fn visit_map<A: MapAccess<'de>>(self, mut values: A) -> Result<Validate, A::Error> {
                while values.next_entry::<String, Validate>()?.is_some() {}
                Ok(Validate)
            }
        }
        deserializer.deserialize_any(VisitorImpl)
    }
}

struct ProjectedAsset(serde_json::Map<String, serde_json::Value>);
impl<'de> serde::Deserialize<'de> for ProjectedAsset {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Fields;
        impl<'de> Visitor<'de> for Fields {
            type Value = ProjectedAsset;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("an asset object") }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut asset = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if matches!(key.as_str(), "id" | "subcategories" | "variant") && !asset.contains_key(&key) {
                        let mut value = map.next_value::<crate::json_parse::FirstValue>()?.0;
                        if key == "variant" {
                            if let serde_json::Value::Object(variant) = &mut value {
                                variant.retain(|key, _| matches!(key.as_str(), "appearance" | "orientation"));
                            }
                        }
                        asset.insert(key, value);
                    } else {
                        map.next_value::<Validate>()?;
                    }
                }
                Ok(ProjectedAsset(asset))
            }
        }
        deserializer.deserialize_map(Fields)
    }
}

struct Manifest<'a>(&'a mut Vec<u8>);
impl<'de> DeserializeSeed<'de> for Manifest<'_> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, deserializer: D) -> Result<(), D::Error> {
        deserializer.deserialize_map(ManifestVisitor(self.0))
    }
}
struct ManifestVisitor<'a>(&'a mut Vec<u8>);
impl<'de> Visitor<'de> for ManifestVisitor<'_> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("an aerial manifest") }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let mut found = false;
        while let Some(key) = map.next_key::<String>()? {
            if key == "assets" {
                if found { return Err(A::Error::custom("duplicate assets")); }
                found = true;
                map.next_value_seed(Assets(self.0))?;
            } else {
                map.next_value::<Validate>()?;
            }
        }
        if !found { return Err(A::Error::custom("missing assets")); }
        Ok(())
    }
}


fn project_reader(reader: impl std::io::Read) -> Option<Vec<u8>> {
    let mut parser = serde_json::Deserializer::from_reader(std::io::BufReader::new(reader));
    let mut output = Vec::new();
    Manifest(&mut output).deserialize(&mut parser).ok()?;
    parser.end().ok()?;
    Some(output)
}

#[cfg(test)]
fn project(bytes: &[u8]) -> Option<Vec<u8>> {
    project_reader(bytes)
}

/// Emits only fields needed by wallpaper selection. Zero requests the legacy parser.
#[no_mangle]
pub unsafe extern "C" fn launchpad_aerial_assets(
    path: *const std::ffi::c_char,
    context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>,
) -> i32 {
    use std::os::unix::ffi::OsStrExt;
    if path.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let path = std::ffi::OsStr::from_bytes(std::ffi::CStr::from_ptr(path).to_bytes());
    let Ok(file) = std::fs::File::open(path) else { return 0 };
    let Some(output) = project_reader(file) else { return 0 };
    callback(context, output.as_ptr(), output.len());
    1
}

#[cfg(test)]
mod tests {
    use super::project;
    use serde_json::json;

    #[test]
    fn keeps_only_selection_fields_and_rejects_invalid_manifests() {
        let input = br#"{"other":[1,2],"assets":[{"id":"a","extra":{"large":[1,2]},"subcategories":["set"],"variant":{"appearance":"dark","orientation":"portrait","unused":5}},{}]}"#;
        let result: serde_json::Value = serde_json::from_slice(&project(input).unwrap()).unwrap();
        assert_eq!(result, json!([{"id":"a","subcategories":["set"],"variant":{"appearance":"dark","orientation":"portrait"}},{}]));
        let duplicate: serde_json::Value = serde_json::from_slice(&project(br#"{"assets":[{"id":"first","id":"second"}]}"#).unwrap()).unwrap();
        assert_eq!(duplicate[0]["id"], "first");
        assert!(project(br#"{"assets":[{"id":"a","unused":"\uD800"}]}"#).is_none());
        for input in [br#"{"assets":[1]}"#.as_slice(), br#"{"assets":[],"assets":[]}"#, br#"{"other":0}"#, br#"{"assets":[] } garbage"#] {
            assert!(project(input).is_none());
        }
    }
}
