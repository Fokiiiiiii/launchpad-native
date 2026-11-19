use std::ffi::CStr;
use std::fs;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// The callback receives the file bytes synchronously; they remain owned here.
#[no_mangle]
pub unsafe extern "C" fn launchpad_read_file(
    path: *const c_char,
    context: *mut std::ffi::c_void,
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize)>,
) -> i32 {
    if path.is_null() { return 22; }
    let Some(callback) = callback else { return 22 };
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    match fs::read(path) {
        Ok(bytes) => { callback(context, bytes.as_ptr(), bytes.len()); 0 }
        Err(error) => error.raw_os_error().filter(|code| *code > 0).unwrap_or(5),
    }
}

/// Emits direct entry names synchronously; zero means the caller must discard them.
#[no_mangle]
pub unsafe extern "C" fn launchpad_directory_entries(
    path: *const c_char,
    context: *mut std::ffi::c_void,
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize)>,
) -> i32 {
    if path.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(metadata) = fs::symlink_metadata(path) else { return 0 };
    if !metadata.file_type().is_dir() { return 0; }
    let Ok(entries) = fs::read_dir(path) else { return 0 };
    for entry in entries {
        let Ok(entry) = entry else { return 0 };
        let name = entry.file_name();
        let bytes = name.as_bytes();
        if std::str::from_utf8(bytes).is_err() { return 0; }
        callback(context, bytes.as_ptr(), bytes.len());
    }
    1
}

/// Emits UTF-8 names and symlink destinations; zero requests the caller's fallback.
#[no_mangle]
pub unsafe extern "C" fn launchpad_photo_links(
    path: *const c_char,
    context: *mut std::ffi::c_void,
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize, *const u8, usize)>,
) -> i32 {
    if path.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let directory = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(entries) = fs::read_dir(directory) else { return 0 };
    for entry in entries {
        let Ok(entry) = entry else { return 0 };
        let name = entry.file_name();
        let name = name.as_bytes();
        if std::str::from_utf8(name).is_err() { return 0; }
        let Ok(target) = fs::read_link(entry.path()) else { continue };
        let target = target.as_os_str().as_bytes();
        if std::str::from_utf8(target).is_err() { return 0; }
        callback(context, name.as_ptr(), name.len(), target.as_ptr(), target.len());
    }
    1
}

/// Returns the target's access time in Unix seconds.
#[no_mangle]
pub unsafe extern "C" fn launchpad_access_time(path: *const c_char, result: *mut f64) -> i32 {
    if path.is_null() || result.is_null() { return 0; }
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Ok(metadata) = fs::metadata(path) else { return 0 };
    let Ok(accessed) = metadata.accessed() else { return 0 };
    let seconds = match accessed.duration_since(std::time::UNIX_EPOCH) {
        Ok(value) => value.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    };
    if !seconds.is_finite() { return 0; }
    *result = seconds;
    1
}

/// Returns one when any validated child exists, zero when none do, and -1 on uncertainty.
#[no_mangle]
pub unsafe extern "C" fn launchpad_nested_exists(
    root: *const c_char,
    names: *const u8,
    length: usize,
) -> i32 {
    if root.is_null() || length > isize::MAX as usize || (names.is_null() && length != 0) { return -1; }
    let root = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(root).to_bytes()));
    let bytes = if length == 0 { &[][..] } else { std::slice::from_raw_parts(names, length) };
    let mut offset = 0;
    while offset < bytes.len() {
        let Some(header) = bytes.get(offset..).and_then(|rest| rest.get(..4)) else { return -1 };
        let size = u32::from_le_bytes([header[0], header[1], header[2], header[3]]) as usize;
        offset += 4;
        let Some(end) = offset.checked_add(size) else { return -1 };
        let Some(name) = bytes.get(offset..end) else { return -1 };
        if crate::catalog::launchpad_safe_identifier(name.as_ptr(), name.len()) == 0 { return -1; }
        let path = root.join(std::ffi::OsStr::from_bytes(name));
        match fs::metadata(path) {
            Ok(_) => return 1,
            Err(error) if matches!(error.raw_os_error(), Some(2 | 20)) => {}
            Err(_) => return -1,
        }
        offset = end;
    }
    0
}

/// Reads at most the supplied limit, even if the source changes during the read.
#[no_mangle]
pub unsafe extern "C" fn launchpad_read_file_limited(
    path: *const c_char,
    limit: usize,
    context: *mut std::ffi::c_void,
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize)>,
) -> i32 {
    use std::io::Read;
    if path.is_null() || limit == usize::MAX { return 22; }
    let Some(callback) = callback else { return 22; };
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let result = (|| -> std::io::Result<Vec<u8>> {
        let file = fs::File::open(path)?;
        let mut data = Vec::new();
        file.take((limit as u64) + 1).read_to_end(&mut data)?;
        Ok(data)
    })();
    match result {
        Ok(data) if data.len() <= limit => { callback(context, data.as_ptr(), data.len()); 0 }
        Ok(_) => 27,
        Err(error) => error.raw_os_error().filter(|code| *code > 0).unwrap_or(5),
    }
}

/// Returns an owned buffer; the caller must release its handle exactly once.
#[no_mangle]
pub unsafe extern "C" fn launchpad_read_owned(path: *const c_char, limit: usize, data: *mut *mut u8, length: *mut usize) -> *mut std::ffi::c_void {
    use std::io::Read;
    if path.is_null() || data.is_null() || length.is_null() { return std::ptr::null_mut(); }
    *data = std::ptr::null_mut();
    *length = 0;
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let result = (|| -> std::io::Result<Vec<u8>> {
        if limit == usize::MAX { return fs::read(path); }
        let mut bytes = Vec::new();
        fs::File::open(path)?.take(limit as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > limit { return Err(std::io::Error::from_raw_os_error(27)); }
        Ok(bytes)
    })();
    let Ok(bytes) = result else { return std::ptr::null_mut(); };
    let mut owned = Box::new(bytes);
    *length = owned.len();
    *data = owned.as_mut_ptr();
    Box::into_raw(owned).cast()
}

/// Releases a handle obtained from `launchpad_read_owned`.
#[no_mangle]
pub unsafe extern "C" fn launchpad_read_owned_free(handle: *mut std::ffi::c_void) {
    if !handle.is_null() { drop(Box::from_raw(handle as *mut Vec<u8>)); }
}

#[cfg(test)]
mod owned_tests {
    use super::*;
    use std::ffi::CString;
    #[test]
    fn owned_read_preserves_bytes_and_enforces_limit() {
        let path = std::env::temp_dir().join(format!("launchpad-owned-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::write(&path, b"abcd").unwrap();
        let name = CString::new(path.as_os_str().as_bytes()).unwrap();
        let mut data = std::ptr::null_mut();
        let mut length = 0;
        assert!(unsafe { launchpad_read_owned(name.as_ptr(), 3, &mut data, &mut length) }.is_null());
        let handle = unsafe { launchpad_read_owned(name.as_ptr(), 4, &mut data, &mut length) };
        assert!(!handle.is_null());
        assert_eq!(unsafe { std::slice::from_raw_parts(data, length) }, b"abcd");
        unsafe { launchpad_read_owned_free(handle) };
        fs::write(&path, []).unwrap();
        let handle = unsafe { launchpad_read_owned(name.as_ptr(), 0, &mut data, &mut length) };
        assert!(!handle.is_null());
        assert_eq!(length, 0);
        unsafe { launchpad_read_owned_free(handle) };
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn nested_existence_checks_valid_names_and_dangling_links() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("nested-check-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("com.example.child"), b"").unwrap();
        symlink(root.join("absent"), root.join("com.example.link")).unwrap();
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        let encode = |name: &[u8]| { let mut out = (name.len() as u32).to_le_bytes().to_vec(); out.extend_from_slice(name); out };
        for (name, expected) in [(b"com.example.child".as_slice(), 1), (b"com.example.link", 0), (b"missing", 0), (b"../unsafe", -1)] {
            let input = encode(name);
            assert_eq!(unsafe { launchpad_nested_exists(path.as_ptr(), input.as_ptr(), input.len()) }, expected);
        }
        assert_eq!(unsafe { launchpad_nested_exists(path.as_ptr(), [3_u8, 0].as_ptr(), 2) }, -1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn photo_links_and_access_times_match_filesystem() {
        use std::os::unix::fs::symlink;
        unsafe extern "C" fn collect(context: *mut std::ffi::c_void, name: *const u8, n: usize, target: *const u8, t: usize) {
            let output = &mut *context.cast::<Vec<(Vec<u8>, Vec<u8>)>>();
            output.push((std::slice::from_raw_parts(name, n).to_vec(), std::slice::from_raw_parts(target, t).to_vec()));
        }
        let root = std::env::temp_dir().join(format!("photo-links-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("photo.png"), b"file").unwrap();
        symlink("photo.png", root.join("picture-link")).unwrap();
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        let mut links = Vec::new();
        let status = unsafe { launchpad_photo_links(path.as_ptr(), (&mut links as *mut Vec<(Vec<u8>, Vec<u8>)>).cast(), Some(collect)) };
        assert_eq!(status, 1);
        assert_eq!(links, vec![(b"picture-link".to_vec(), b"photo.png".to_vec())]);
        let file = CString::new(root.join("photo.png").as_os_str().as_bytes()).unwrap();
        let mut seconds = 0.0;
        assert_eq!(unsafe { launchpad_access_time(file.as_ptr(), &mut seconds) }, 1);
        let expected = fs::metadata(root.join("photo.png")).unwrap().accessed().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
        assert!((seconds - expected).abs() < 0.000_001);
        fs::remove_dir_all(root).unwrap();
    }
}

unsafe fn write_atomic(
    path: *const c_char, bytes: *const u8, length: usize, durable: bool,
) -> i32 {
    use std::io::Write;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    extern "C" { fn fsync(fd: i32) -> i32; }
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    if path.is_null() || (bytes.is_null() && length != 0) { return 22; }
    let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    let Some(parent) = path.parent() else { return 22; };
    let Some(name) = path.file_name() else { return 22; };
    let data = if length == 0 { &[] } else { std::slice::from_raw_parts(bytes, length) };
    let mut temp_name = name.to_os_string();
    temp_name.push(format!(".tmp-{}-{}", std::process::id(), SEQUENCE.fetch_add(1, Ordering::Relaxed)));
    let temp = parent.join(temp_name);
    let mut created = false;
    let result = (|| -> std::io::Result<()> {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp)?;
        created = true;
        file.write_all(data)?;
        // `File::sync_all` is `F_FULLFSYNC` on macOS: it waits for the drive to empty its own
        // cache, about 3 ms a write, and a layout is written (twice, with its backup) on every
        // edit. `fsync(2)` hands the data to the drive, which is what SQLite and Core Data do by
        // default (measured: 224 us, against 205 us for no flush at all). The last-known-good
        // backup is what covers losing power in the window between the drive's cache and the media.
        if durable && unsafe { fsync(file.as_raw_fd()) } != 0 { return Err(std::io::Error::last_os_error()); }
        drop(file);
        fs::rename(&temp, path)
    })();
    if let Err(error) = result {
        // Only remove the temporary file if this call created it.
        if created { let _ = fs::remove_file(&temp); }
        return error.raw_os_error().filter(|code| *code > 0).unwrap_or(5);
    }
    0
}

/// Atomically writes durable user data, flushed with `fsync(2)` before the rename.
#[no_mangle]
pub unsafe extern "C" fn launchpad_write_file_atomic(path: *const c_char, bytes: *const u8, length: usize) -> i32 {
    write_atomic(path, bytes, length, true)
}

/// Atomically replaces regenerable cache data without a synchronous disk flush.
#[no_mangle]
pub unsafe extern "C" fn launchpad_write_cache_atomic(path: *const c_char, bytes: *const u8, length: usize) -> i32 {
    write_atomic(path, bytes, length, false)
}

#[path = "watcher.rs"]
pub mod watcher;
