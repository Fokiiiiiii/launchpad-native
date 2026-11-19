use std::ffi::CStr;
use std::fs;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, MutexGuard};

/// Entries looked at on the calling thread before any helper is started. Most paths asked about
/// are small, and starting threads costs more than walking them.
const SERIAL_BUDGET: usize = 512;
const MAX_WORKERS: usize = 8;

/// Lists one directory: subfolders go to `queue`, everything else adds its allocated size to
/// `total`. Returns how many entries it looked at.
fn scan_directory(directory: &Path, queue: &mut Vec<PathBuf>, total: &mut u64) -> usize {
    let Ok(entries) = fs::read_dir(directory) else { return 0 };
    let mut seen = 0;
    for entry in entries.flatten() {
        seen += 1;
        // readdir has already said what the entry is; only a file needs a stat, for its size.
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => queue.push(entry.path()),
            Ok(_) => {
                if let Ok(metadata) = fs::symlink_metadata(entry.path()) {
                    *total = total.saturating_add(metadata.blocks().saturating_mul(512));
                }
            }
            Err(_) => {}
        }
    }
    seen
}

struct State { queue: Vec<PathBuf>, active: usize }
struct Shared { state: Mutex<State>, wake: Condvar }

fn locked(shared: &Shared) -> MutexGuard<'_, State> {
    shared.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Takes folders off the shared queue until none is queued and none is being listed (a folder
/// being listed may still add more).
fn work(shared: &Shared) -> u64 {
    let mut total = 0;
    let mut found = Vec::new();
    loop {
        let directory = {
            let mut state = locked(shared);
            loop {
                if let Some(directory) = state.queue.pop() { state.active += 1; break Some(directory); }
                if state.active == 0 { break None; }
                state = shared.wake.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner());
            }
        };
        let Some(directory) = directory else { shared.wake.notify_all(); return total };
        found.clear();
        scan_directory(&directory, &mut found, &mut total);
        let mut state = locked(shared);
        state.queue.append(&mut found);
        state.active -= 1;
        drop(state);
        shared.wake.notify_all();
    }
}

fn parallel(queue: Vec<PathBuf>) -> u64 {
    let workers = std::thread::available_parallelism().map_or(4, |count| count.get()).clamp(2, MAX_WORKERS);
    let shared = Shared { state: Mutex::new(State { queue, active: 0 }), wake: Condvar::new() };
    std::thread::scope(|scope| {
        // A thread that cannot be started just means fewer helpers; this one works too.
        let helpers: Vec<_> = (1..workers)
            .filter_map(|_| std::thread::Builder::new().spawn_scoped(scope, || work(&shared)).ok())
            .collect();
        let mut total = work(&shared);
        for helper in helpers { total = total.saturating_add(helper.join().unwrap_or(0)); }
        total
    })
}

pub(crate) fn disk_usage(path: &Path) -> i64 {
    let Ok(root) = fs::metadata(path) else { return 0 };
    if !root.is_dir() {
        return fs::symlink_metadata(path)
            .map(|metadata| metadata.len().min(i64::MAX as u64) as i64)
            .unwrap_or(0);
    }
    let mut queue = vec![path.to_path_buf()];
    let mut total = 0_u64;
    let mut seen = 0;
    while let Some(directory) = queue.pop() {
        seen += scan_directory(&directory, &mut queue, &mut total);
        // A big tree is where the time goes; walk it on every core.
        if seen >= SERIAL_BUDGET && !queue.is_empty() {
            total = total.saturating_add(parallel(queue));
            break;
        }
    }
    total.min(i64::MAX as u64) as i64
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
    use std::time::{SystemTime, UNIX_EPOCH};

    /// The plain recursive walk the parallel one must agree with.
    fn reference(path: &Path) -> u64 {
        let mut total = 0_u64;
        for entry in fs::read_dir(path).unwrap().flatten() {
            let metadata = fs::symlink_metadata(entry.path()).unwrap();
            if metadata.is_dir() { total += reference(&entry.path()); } else { total += metadata.blocks() * 512; }
        }
        total
    }

    #[test]
    fn a_tree_past_the_serial_budget_is_counted_the_same_by_the_parallel_walk() {
        let base = std::env::temp_dir().join(format!("launchpad-usage-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        for folder in 0..40 {
            let directory = base.join(format!("d{folder}")).join("nested");
            fs::create_dir_all(&directory).unwrap();
            for file in 0..20 {
                fs::write(base.join(format!("d{folder}")).join(format!("f{file}")), vec![1_u8; 100 + file * 700]).unwrap();
                fs::write(directory.join(format!("n{file}")), vec![2_u8; 50 + file * 1300]).unwrap();
            }
        }
        std::os::unix::fs::symlink(&base, base.join("d0").join("loop")).unwrap();
        let entries = 40 * (1 + 20 + 20);
        assert!(entries > SERIAL_BUDGET, "the tree must be big enough to take the parallel path");
        assert_eq!(disk_usage(&base), reference(&base) as i64);
        fs::remove_dir_all(base).unwrap();
    }
}
