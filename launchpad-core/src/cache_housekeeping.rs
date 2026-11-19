use std::ffi::CStr;
use std::fs;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

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

#[path = "memory_cache.rs"]
pub mod memory_cache;

#[path = "aerial.rs"]
pub mod aerial;
