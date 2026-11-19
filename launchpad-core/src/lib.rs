#[cfg(test)] use std::ffi::CStr;
#[cfg(test)] use std::fs;
#[cfg(test)] use std::os::raw::c_char;
#[cfg(test)] use std::os::unix::ffi::OsStrExt;
#[cfg(test)] use std::os::unix::fs::MetadataExt;

#[path = "fs.rs"]
mod fs_ops;

mod layout;

mod json_parse;

pub use layout::launchpad_layout_repack;

pub use layout::launchpad_layout_move_one;
pub use layout::launchpad_layout_reorder;

pub use fs_ops::{launchpad_read_owned, launchpad_read_owned_free};

pub use fs_ops::launchpad_write_cache_atomic;

pub use fs_ops::watcher::{launchpad_watch_start, launchpad_watch_stop};
mod disk_usage;
mod search;

pub use search::launchpad_match_graphemes;
mod catalog;

pub use catalog::reconcile::launchpad_order_records;

pub use catalog::reconcile::launchpad_match_moved_apps;

pub use catalog::snapshot::{launchpad_catalog_encode, launchpad_catalog_decode};

pub use catalog::launchpad_catalog_fresh;
mod cache_housekeeping;

#[cfg(test)] pub(crate) use disk_usage::disk_usage;

pub use disk_usage::launchpad_disk_usage;

pub use catalog::launchpad_safe_identifier;

pub use catalog::launchpad_classify_special_key;

pub use fs_ops::launchpad_read_file;

pub use fs_ops::launchpad_read_file_limited;

pub use fs_ops::launchpad_write_file_atomic;

pub use search::launchpad_search_tier;

pub use cache_housekeeping::launchpad_trim_icon_cache;

pub use catalog::launchpad_scan_apps;

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn counts_files_without_following_directory_symlinks() {
        let base = std::env::temp_dir().join(format!("launchpad-core-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(base.join("nested")).unwrap();
        let file = base.join("nested/file");
        fs::write(&file, b"hello").unwrap();
        symlink(&base, base.join("nested/loop")).unwrap();
        let expected = fs::symlink_metadata(&file).unwrap().blocks() * 512
            + fs::symlink_metadata(base.join("nested/loop")).unwrap().blocks() * 512;
        assert_eq!(disk_usage(&base), expected as i64);
        assert_eq!(disk_usage(&file), 5);
        assert_eq!(disk_usage(&base.join("missing")), 0);
        fs::remove_dir_all(base).unwrap();
    }

#[test]
    fn trims_only_visible_png_files_and_preserves_other_entries() {
        use std::ffi::CString;
        use std::time::Duration;
        let base = std::env::temp_dir().join(format!("launchpad-cache-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(base.join("folder.png")).unwrap();
        for (index, name) in ["old.png", "new.png"].iter().enumerate() {
            let file = fs::File::create(base.join(name)).unwrap();
            file.set_len(1000).unwrap();
            file.set_modified(UNIX_EPOCH + Duration::from_secs(1000 + index as u64)).unwrap();
        }
        fs::write(base.join(".hidden.png"), b"keep").unwrap();
        fs::write(base.join("other.txt"), b"keep").unwrap();
        let path = CString::new(base.as_os_str().as_bytes()).unwrap();
        unsafe { launchpad_trim_icon_cache(path.as_ptr(), 1000) };
        assert!(!base.join("old.png").exists());
        assert!(base.join("new.png").exists());
        assert!(base.join(".hidden.png").exists());
        assert!(base.join("other.txt").exists());
        assert!(base.join("folder.png").is_dir());
        fs::remove_dir_all(base).unwrap();
    }

#[test]
    fn scan_skips_hidden_entries_and_nested_app_contents() {
        use std::ffi::CString;
        unsafe extern "C" fn collect(context: *mut std::ffi::c_void, path: *const c_char, kind: i32) {
            let results = &mut *(context as *mut Vec<(Vec<u8>, i32)>);
            results.push((CStr::from_ptr(path).to_bytes().to_vec(), kind));
        }
        let base = std::env::temp_dir().join(format!("launchpad-scan-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(base.join("outer/First.app/Contents/Inner.app")).unwrap();
        fs::create_dir_all(base.join(".hidden/Hidden.app")).unwrap();
        fs::create_dir_all(base.join("Top.app")).unwrap();
        let path = CString::new(base.as_os_str().as_bytes()).unwrap();
        let mut results: Vec<(Vec<u8>, i32)> = Vec::new();
        assert_eq!(unsafe { launchpad_scan_apps(path.as_ptr(), 1, &mut results as *mut _ as *mut _, Some(collect)) }, 1);
        assert_eq!(results.len(), 2);
        assert!(results.iter().any(|(path, kind)| path.ends_with(b"First.app") && *kind == 0));
        assert!(results.iter().any(|(path, kind)| path.ends_with(b"Top.app") && *kind == 0));
        results.clear();
        assert_eq!(unsafe { launchpad_scan_apps(path.as_ptr(), 0, &mut results as *mut _ as *mut _, Some(collect)) }, 1);
        assert_eq!(results.len(), 1);
        let missing = CString::new(base.join("missing").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { launchpad_scan_apps(missing.as_ptr(), 1, &mut results as *mut _ as *mut _, Some(collect)) }, 0);
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn identifiers_reject_unsafe_and_non_ascii_bytes() {
        for value in [b"".as_slice(), b"..", b".hidden", b"a/b", b"x\0y", "日本".as_bytes()] {
            assert_eq!(unsafe { launchpad_safe_identifier(value.as_ptr(), value.len()) }, 0);
        }
        let valid = b"com.example-App_1";
        assert_eq!(unsafe { launchpad_safe_identifier(valid.as_ptr(), valid.len()) }, 1);
        assert_eq!(unsafe { launchpad_safe_identifier(std::ptr::null(), 0) }, 0);
        let too_long = [b'a'; 256];
        assert_eq!(unsafe { launchpad_safe_identifier(too_long.as_ptr(), too_long.len()) }, 0);
    }

    #[test]
    fn special_key_decoding_keeps_release_and_repeat_distinct() {
        assert_eq!(launchpad_classify_special_key(7, 0), -1);
        assert_eq!(launchpad_classify_special_key(8, (13 << 16) | 0x100), 13 | (1 << 16));
        assert_eq!(launchpad_classify_special_key(8, (13 << 16) | 0x101), 13 | (1 << 16) | (1 << 17));
        assert_eq!(launchpad_classify_special_key(8, (13 << 16) | 0x0a00), 13);
    }

    #[test]
    fn file_reader_preserves_bytes_and_reports_missing_files() {
        use std::ffi::CString;
        unsafe extern "C" fn collect(context: *mut std::ffi::c_void, data: *const u8, len: usize) {
            let result = &mut *(context as *mut Vec<u8>);
            result.extend_from_slice(std::slice::from_raw_parts(data, len));
        }
        let base = std::env::temp_dir().join(format!("launchpad-read-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::write(&base, [0, 0xff, 1]).unwrap();
        let path = CString::new(base.as_os_str().as_bytes()).unwrap();
        let mut result: Vec<u8> = Vec::new();
        assert_eq!(unsafe { launchpad_read_file(path.as_ptr(), &mut result as *mut _ as *mut _, Some(collect)) }, 0);
        assert_eq!(result, [0, 0xff, 1]);
        fs::remove_file(&base).unwrap();
        assert_ne!(unsafe { launchpad_read_file(path.as_ptr(), &mut result as *mut _ as *mut _, Some(collect)) }, 0);
    }

    #[test]
    fn bounded_reader_rejects_oversized_input() {
        use std::ffi::CString;
        unsafe extern "C" fn collect(context: *mut std::ffi::c_void, data: *const u8, len: usize) {
            let result = &mut *(context as *mut Vec<u8>);
            result.extend_from_slice(std::slice::from_raw_parts(data, len));
        }
        let base = std::env::temp_dir().join(format!("launchpad-limit-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::write(&base, b"abcd").unwrap();
        let path = CString::new(base.as_os_str().as_bytes()).unwrap();
        let mut result: Vec<u8> = Vec::new();
        let context = &mut result as *mut _ as *mut _;
        assert_eq!(unsafe { launchpad_read_file_limited(path.as_ptr(), 3, context, Some(collect)) }, 27);
        assert!(result.is_empty());
        assert_eq!(unsafe { launchpad_read_file_limited(path.as_ptr(), 4, context, Some(collect)) }, 0);
        assert_eq!(result, b"abcd");
        fs::remove_file(base).unwrap();
    }

    #[test]
    fn atomic_write_replaces_content_and_reports_failure() {
        use std::ffi::CString;
        let base = std::env::temp_dir().join(format!("launchpad-write-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir(&base).unwrap();
        let target = base.join("layout.json");
        fs::write(&target, b"old").unwrap();
        let path = CString::new(target.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { launchpad_write_file_atomic(path.as_ptr(), b"new".as_ptr(), 3) }, 0);
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert_eq!(unsafe { launchpad_write_cache_atomic(path.as_ptr(), b"cache".as_ptr(), 5) }, 0);
        assert_eq!(fs::read(&target).unwrap(), b"cache");
        let missing = CString::new(base.join("missing/layout.json").as_os_str().as_bytes()).unwrap();
        assert_ne!(unsafe { launchpad_write_file_atomic(missing.as_ptr(), b"bad".as_ptr(), 3) }, 0);
        assert_eq!(fs::read(&target).unwrap(), b"cache");
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn search_rejects_incomplete_input() {
        let malformed = [7u8, 0, 0, 0, b'a'];
        assert_eq!(unsafe { launchpad_search_tier(malformed.as_ptr(), malformed.len()) }, -1);
    }
}
