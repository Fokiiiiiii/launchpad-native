use std::ffi::CStr;
use std::fs;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

fn disk_usage(path: &Path) -> i64 {
    let Ok(root) = fs::metadata(path) else { return 0 };
    if !root.is_dir() {
        return fs::symlink_metadata(path)
            .map(|metadata| metadata.len().min(i64::MAX as u64) as i64)
            .unwrap_or(0);
    }
    let mut directories = vec![path.to_path_buf()];
    let mut total = 0_i64;
    while let Some(directory) = directories.pop() {
        let Ok(entries) = fs::read_dir(directory) else { continue };
        for entry in entries.flatten() {
            let Ok(metadata) = fs::symlink_metadata(entry.path()) else { continue };
            if metadata.is_dir() {
                directories.push(entry.path());
            } else {
                total = total.saturating_add(metadata.blocks().saturating_mul(512).min(i64::MAX as u64) as i64);
            }
        }
    }
    total
}

/// The caller supplies a valid, NUL-terminated filesystem path for this call.
#[no_mangle]
pub unsafe extern "C" fn launchpad_disk_usage(path: *const c_char) -> i64 {
    if path.is_null() { return 0; }
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    disk_usage(path)
}

/// The caller supplies a valid, NUL-terminated cache directory path.
#[no_mangle]
pub unsafe extern "C" fn launchpad_trim_icon_cache(path: *const c_char, budget: i64) {
    use std::os::macos::fs::MetadataExt as MacMetadataExt;
    if path.is_null() { return; }
    let directory = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(entries) = fs::read_dir(directory) else { return };
    let mut files = Vec::new();
    let mut total = 0_u64;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.as_bytes();
        if name.starts_with(b".") || !name.ends_with(b".png") { continue; }
        let Ok(metadata) = fs::symlink_metadata(entry.path()) else { continue };
        if metadata.st_flags() & 0x8000 != 0 || (!metadata.is_file() && !metadata.file_type().is_symlink()) { continue; }
        total = total.saturating_add(metadata.len());
        files.push((metadata.modified().ok(), entry.path(), metadata.len()));
    }
    files.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
    for (_, file, size) in files {
        if budget >= 0 && total <= budget as u64 { break; }
        if fs::remove_file(file).is_ok() { total = total.saturating_sub(size); }
    }
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
        let metadata = match fs::symlink_metadata(&entry_path) {
            Ok(metadata) => metadata,
            Err(_) => {
                if let Ok(path) = CString::new(directory.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); }
                continue;
            }
        };
        if metadata.st_flags() & 0x8000 != 0 { continue; }
        if entry_path.extension().is_some_and(|ext| ext.as_bytes() == b"app") {
            if let Ok(path) = CString::new(entry_path.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 0); }
        } else if recursive != 0 && metadata.is_dir() {
            match fs::read_dir(&entry_path) {
                Ok(children) => stack.push((entry_path, children)),
                Err(_) => if let Ok(path) = CString::new(entry_path.as_os_str().as_bytes()) { callback(context, path.as_ptr(), 1); },
            }
        }
    }
    1
}

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
}
