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
}
