use std::ffi::CStr;
use std::fs;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// The caller supplies a readable buffer of `length` bytes.
#[no_mangle]
pub unsafe extern "C" fn launchpad_safe_identifier(bytes: *const u8, length: usize) -> i32 {
    if bytes.is_null() || length == 0 || length > 255 { return 0; }
    let value = std::slice::from_raw_parts(bytes, length);
    if !value[0].is_ascii_alphanumeric() || value.windows(2).any(|pair| pair == b"..") { return 0; }
    i32::from(value.iter().all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'.' | b'_' | b'-')))
}

#[no_mangle]
pub extern "C" fn launchpad_classify_special_key(subtype: i64, data1: i64) -> i64 {
    if subtype != 8 { return -1; }
    let raw = data1 as u64;
    let key = (raw >> 16) & 0xffff;
    let down = u64::from(((raw >> 8) & 0xff) == 1);
    let repeated = raw & 1;
    (key | (down << 16) | (repeated << 17)) as i64
}

/// Reports app paths (kind 0) and unreadable directories (kind 1) synchronously.
#[no_mangle]
pub unsafe extern "C" fn launchpad_scan_apps(
    path: *const c_char,
    recursive: i32,
    context: *mut std::ffi::c_void,
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const c_char, i32)>,
) -> i32 {
    use std::ffi::CString;
    use std::os::macos::fs::MetadataExt as MacMetadataExt;
    if path.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let root = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(entries) = fs::read_dir(root) else { return 0 };
    let mut stack = vec![(root.to_path_buf(), entries)];
    while let Some((directory, entries)) = stack.last_mut() {
        let entry = match entries.next() {
            None => { stack.pop(); continue; }
            Some(Ok(entry)) => entry,
            Some(Err(_)) => {
                if let Ok(path) = CString::new(directory.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); }
                continue;
            }
        };
        let name = entry.file_name();
        if name.as_bytes().starts_with(b".") { continue; }
        let entry_path = entry.path();
        let is_app = entry_path.extension().is_some_and(|ext| ext.as_bytes() == b"app");
        // readdir has already said what the entry is, for free. Only a bundle or a folder to
        // walk into can matter, and only those need the stat that reads the hidden flag; files
        // are nearly everything in a tree like Adobe's, and a stat each was most of the time.
        let is_dir = match entry.file_type() {
            Ok(kind) => kind.is_dir(),
            Err(_) => {
                if let Ok(path) = CString::new(directory.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); }
                continue;
            }
        };
        if !is_app && !(recursive != 0 && is_dir) { continue; }
        let metadata = match fs::symlink_metadata(&entry_path) {
            Ok(metadata) => metadata,
            Err(_) => {
                if let Ok(path) = CString::new(directory.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); }
                continue;
            }
        };
        if metadata.st_flags() & 0x8000 != 0 { continue; }
        if is_app {
            if let Ok(path) = CString::new(entry_path.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 0); }
        } else {
            match fs::read_dir(&entry_path) {
                Ok(children) => stack.push((entry_path, children)),
                Err(_) => if let Ok(path) = CString::new(entry_path.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); },
            }
        }
    }
    1
}

/// The caller supplies a valid path and an Apple-reference-date timestamp.
#[no_mangle]
pub unsafe extern "C" fn launchpad_catalog_fresh(path: *const c_char, expected: f64) -> i32 {
    if path.is_null() || !expected.is_finite() { return 0; }
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(metadata) = fs::metadata(path) else { return 0; };
    if !metadata.is_dir() { return 0; }
    let Ok(modified) = metadata.modified() else { return 0; };
    let seconds = match modified.duration_since(std::time::UNIX_EPOCH) {
        Ok(value) => value.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    };
    i32::from((seconds - 978_307_200.0 - expected).abs() < 1.0)
}

#[path = "receipts.rs"]
pub mod receipts;

#[path = "legacy.rs"]
pub mod legacy;

#[path = "catalog_snapshot.rs"]
pub mod snapshot;

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    #[test]
    fn freshness_rejects_missing_files_and_stale_directories() {
        let root = std::env::temp_dir().join(format!("catalog-fresh-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir(&root).unwrap();
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        let modified = fs::metadata(&root).unwrap().modified().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64() - 978_307_200.0;
        assert_eq!(unsafe { launchpad_catalog_fresh(path.as_ptr(), modified) }, 1);
        assert_eq!(unsafe { launchpad_catalog_fresh(path.as_ptr(), modified - 5.0) }, 0);
        fs::remove_dir(&root).unwrap();
        assert_eq!(unsafe { launchpad_catalog_fresh(path.as_ptr(), modified) }, 0);
    }
}
