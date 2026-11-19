use std::ffi::{c_char, c_void};
use std::ptr;

type ChangeCallback = unsafe extern "C" fn(*mut c_void, *const *const c_char, usize, i32);

#[repr(C)]
struct StreamContext {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

struct CallbackState { context: *mut c_void, callback: ChangeCallback }
pub struct Watcher { stream: *mut c_void, queue: *mut c_void, state: Box<CallbackState> }

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeArrayCallBacks: u8;
    fn CFStringCreateWithCString(allocator: *const c_void, text: *const c_char, encoding: u32) -> *const c_void;
    fn CFArrayCreate(allocator: *const c_void, values: *const *const c_void, count: isize, callbacks: *const c_void) -> *const c_void;
    fn CFRelease(value: *const c_void);
}

#[link(name = "CoreServices", kind = "framework")]
extern "C" {
    fn FSEventStreamCreate(allocator: *const c_void, callback: unsafe extern "C" fn(*const c_void, *mut c_void, usize, *mut c_void, *const u32, *const u64), context: *mut StreamContext, paths: *const c_void, since: u64, latency: f64, flags: u32) -> *mut c_void;
    fn FSEventStreamSetDispatchQueue(stream: *mut c_void, queue: *mut c_void);
    fn FSEventStreamStart(stream: *mut c_void) -> u8;
    fn FSEventStreamStop(stream: *mut c_void);
    fn FSEventStreamInvalidate(stream: *mut c_void);
    fn FSEventStreamRelease(stream: *mut c_void);
}

extern "C" {
    fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
    fn dispatch_sync_f(queue: *mut c_void, context: *mut c_void, work: unsafe extern "C" fn(*mut c_void));
    fn dispatch_release(object: *mut c_void);
}

unsafe extern "C" fn callback(_stream: *const c_void, info: *mut c_void, count: usize, paths: *mut c_void, flags: *const u32, _ids: *const u64) {
    if info.is_null() || paths.is_null() || flags.is_null() { return; }
    let state = &*(info as *const CallbackState);
    let unreliable = std::slice::from_raw_parts(flags, count).iter().any(|flag| flag & 0xef != 0);
    (state.callback)(state.context, if unreliable { ptr::null() } else { paths as *const *const c_char }, if unreliable { 0 } else { count }, i32::from(unreliable));
}

/// `paths` and the callback context must remain valid as specified by the caller.
#[no_mangle]
pub unsafe extern "C" fn launchpad_watch_start(paths: *const *const c_char, count: usize, latency: f64, context: *mut c_void, on_change: Option<ChangeCallback>) -> *mut Watcher {
    if paths.is_null() || count == 0 || count > isize::MAX as usize || !latency.is_finite() || latency < 0.0 { return ptr::null_mut(); }
    let Some(on_change) = on_change else { return ptr::null_mut() };
    let mut strings = Vec::with_capacity(count);
    for path in std::slice::from_raw_parts(paths, count) {
        if path.is_null() { for string in strings { CFRelease(string); } return ptr::null_mut(); }
        let string = CFStringCreateWithCString(ptr::null(), *path, 0x0800_0100);
        if string.is_null() { for string in strings { CFRelease(string); } return ptr::null_mut(); }
        strings.push(string);
    }
    let array = CFArrayCreate(ptr::null(), strings.as_ptr(), strings.len() as isize, ptr::addr_of!(kCFTypeArrayCallBacks).cast());
    for string in strings { CFRelease(string); }
    if array.is_null() { return ptr::null_mut(); }
    let mut state = Box::new(CallbackState { context, callback: on_change });
    let mut stream_context = StreamContext { version: 0, info: (&mut *state as *mut CallbackState).cast(), retain: ptr::null(), release: ptr::null(), copy_description: ptr::null() };
    let stream = FSEventStreamCreate(ptr::null(), callback, &mut stream_context, array, u64::MAX, latency, 0x16);
    CFRelease(array);
    if stream.is_null() { return ptr::null_mut(); }
    let queue = dispatch_queue_create(c"com.launchpadnative.catalog.fsevents".as_ptr(), ptr::null());
    if queue.is_null() { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return ptr::null_mut(); }
    FSEventStreamSetDispatchQueue(stream, queue);
    if FSEventStreamStart(stream) == 0 {
        FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); dispatch_release(queue); return ptr::null_mut();
    }
    Box::into_raw(Box::new(Watcher { stream, queue, state }))
}

unsafe extern "C" fn barrier(_: *mut c_void) {}

/// Stop from outside the watch callback; it waits for queued callbacks to finish.
#[no_mangle]
pub unsafe extern "C" fn launchpad_watch_stop(handle: *mut Watcher) {
    if handle.is_null() { return; }
    let watcher = Box::from_raw(handle);
    FSEventStreamStop(watcher.stream);
    FSEventStreamInvalidate(watcher.stream);
    dispatch_sync_f(watcher.queue, ptr::null_mut(), barrier);
    FSEventStreamRelease(watcher.stream);
    dispatch_release(watcher.queue);
    drop(watcher.state);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::os::unix::ffi::OsStrExt;
    use std::sync::mpsc;
    use std::time::Duration;
    unsafe extern "C" fn receive(context: *mut c_void, paths: *const *const c_char, count: usize, rescan: i32) {
        let tx = &*(context as *const mpsc::Sender<String>);
        if rescan != 0 { let _ = tx.send(String::from("rescan")); return; }
        for path in std::slice::from_raw_parts(paths, count) {
            let _ = tx.send(CStr::from_ptr(*path).to_string_lossy().into_owned());
        }
    }
    #[test]
    fn watcher_detects_creation_and_can_stop() {
        let root = std::env::temp_dir().join(format!("launchpad-watch-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir(&root).unwrap();
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        let (tx, rx) = mpsc::channel::<String>();
        let paths = [path.as_ptr()];
        let watcher = unsafe { launchpad_watch_start(paths.as_ptr(), 1, 0.05, (&tx as *const mpsc::Sender<String>).cast_mut().cast(), Some(receive)) };
        assert!(!watcher.is_null());
        struct Guard(*mut Watcher);
        impl Drop for Guard { fn drop(&mut self) { unsafe { launchpad_watch_stop(self.0) } } }
        let guard = Guard(watcher);
        let mut timings = Vec::new();
        for index in 0..5 {
            let name = format!("new{index}.app");
            let start = std::time::Instant::now();
            std::fs::write(root.join(&name), b"test").unwrap();
            let deadline = start + Duration::from_secs(8);
            let mut found = false;
            while std::time::Instant::now() < deadline {
                if let Ok(event) = rx.recv_timeout(Duration::from_millis(250)) {
                    if event.ends_with(&name) || event == "rescan" { found = true; break; }
                }
            }
            assert!(found, "creation event not received");
            timings.push(start.elapsed().as_micros());
        }
        timings.sort_unstable();
        eprintln!("WATCH_BENCH microseconds: min={} median={} max={}", timings[0], timings[2], timings[4]);
        drop(guard);
        while rx.try_recv().is_ok() {}
        std::fs::write(root.join("after-stop.app"), b"test").unwrap();
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
