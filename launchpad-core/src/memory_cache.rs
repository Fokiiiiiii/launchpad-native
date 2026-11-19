use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr;

struct Entry { id: u64, cost: u64, tick: u64 }
struct MemoryCache {
    entries: HashMap<Vec<u8>, Entry>,
    total: u128,
    max_cost: u64,
    max_items: usize,
    tick: u64,
    next_id: u64,
}
impl MemoryCache {
    fn tick(&mut self) -> u64 {
        self.tick = self.tick.saturating_add(1);
        self.tick
    }
}

#[no_mangle]
pub extern "C" fn launchpad_memory_cache_new(max_cost: u64, max_items: usize) -> *mut c_void {
    if max_items == 0 { return ptr::null_mut(); }
    let cache = MemoryCache { entries: HashMap::new(), total: 0, max_cost, max_items, tick: 0, next_id: 1 };
    Box::into_raw(Box::new(cache)).cast()
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_memory_cache_free(cache: *mut c_void) {
    if !cache.is_null() { drop(Box::from_raw(cache.cast::<MemoryCache>())); }
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_memory_cache_clear(cache: *mut c_void) {
    if let Some(cache) = cache.cast::<MemoryCache>().as_mut() {
        cache.entries.clear();
        cache.total = 0;
    }
}

unsafe fn key<'a>(bytes: *const u8, length: usize) -> Option<&'a [u8]> {
    if length > isize::MAX as usize || (bytes.is_null() && length != 0) { return None; }
    Some(if length == 0 { &[] } else { std::slice::from_raw_parts(bytes, length) })
}

#[no_mangle]
pub unsafe extern "C" fn launchpad_memory_cache_touch(cache: *mut c_void, bytes: *const u8, length: usize) -> u64 {
    let Some(cache) = cache.cast::<MemoryCache>().as_mut() else { return 0 };
    let Some(key) = key(bytes, length) else { return 0 };
    if !cache.entries.contains_key(key) { return 0; }
    let tick = cache.tick();
    let entry = cache.entries.get_mut(key).unwrap();
    entry.tick = tick;
    entry.id
}

/// Mutates under the caller's lock and emits evicted IDs synchronously.
#[no_mangle]
pub unsafe extern "C" fn launchpad_memory_cache_put(
    cache: *mut c_void, bytes: *const u8, length: usize, cost: u64,
    context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u64, usize)>,
) -> u64 {
    let Some(cache) = cache.cast::<MemoryCache>().as_mut() else { return 0 };
    let Some(key) = key(bytes, length) else { return 0 };
    let Some(callback) = callback else { return 0 };
    let mut evicted = Vec::new();
    let old = cache.entries.remove(key);
    let was_cached = old.is_some();
    let id = match old {
        Some(entry) => { cache.total -= entry.cost as u128; entry.id }
        None => {
            let id = cache.next_id;
            let Some(next) = id.checked_add(1) else { return 0 };
            cache.next_id = next;
            id
        }
    };
    if cost > cache.max_cost || cache.max_items == 0 {
        if was_cached { evicted.push(id); }
        if !evicted.is_empty() { callback(context, evicted.as_ptr(), evicted.len()); }
        return 0;
    }
    let tick = cache.tick();
    cache.entries.insert(key.to_vec(), Entry { id, cost, tick });
    cache.total += cost as u128;
    while cache.total > cache.max_cost as u128 || cache.entries.len() > cache.max_items {
        let Some(oldest) = cache.entries.iter().min_by_key(|(_, value)| value.tick).map(|(key, _)| key.clone()) else { break };
        let entry = cache.entries.remove(&oldest).unwrap();
        cache.total -= entry.cost as u128;
        evicted.push(entry.id);
    }
    let kept = cache.entries.get(key).is_some();
    if !evicted.is_empty() { callback(context, evicted.as_ptr(), evicted.len()); }
    if kept { id } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    unsafe extern "C" fn collect(context: *mut c_void, ids: *const u64, length: usize) {
        let out = &mut *context.cast::<Vec<u64>>();
        out.extend_from_slice(std::slice::from_raw_parts(ids, length));
    }
    #[test]
    fn respects_cost_and_recency_and_replaces_oversized_entries() {
        unsafe {
            let cache = launchpad_memory_cache_new(10, 3);
            let mut removed = Vec::new();
            let context = (&mut removed as *mut Vec<u64>).cast();
            let put = |key: &[u8], cost, context| launchpad_memory_cache_put(cache, key.as_ptr(), key.len(), cost, context, Some(collect));
            let a = put(b"a", 4, context);
            let b = put(b"b", 4, context);
            assert_eq!(launchpad_memory_cache_touch(cache, b"a".as_ptr(), 1), a);
            let c = put(b"c", 4, context);
            assert_eq!(removed, vec![b]);
            assert_eq!(launchpad_memory_cache_touch(cache, b"c".as_ptr(), 1), c);
            assert_eq!(put(b"a", 11, context), 0);
            assert_eq!(removed, vec![b, a]);
            assert_eq!(launchpad_memory_cache_touch(cache, b"a".as_ptr(), 1), 0);
            assert_eq!(launchpad_memory_cache_touch(cache, b"c".as_ptr(), 1), c);
            launchpad_memory_cache_clear(cache);
            assert_eq!(launchpad_memory_cache_touch(cache, b"c".as_ptr(), 1), 0);
            launchpad_memory_cache_free(cache);
        }
    }
}
