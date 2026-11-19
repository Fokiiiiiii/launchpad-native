use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr;

#[link(name = "sqlite3")]
extern "C" {
    fn sqlite3_open_v2(path: *const c_char, db: *mut *mut c_void, flags: c_int, vfs: *const c_char) -> c_int;
    fn sqlite3_close(db: *mut c_void) -> c_int;
    fn sqlite3_prepare_v2(db: *mut c_void, sql: *const c_char, size: c_int, stmt: *mut *mut c_void, tail: *mut *const c_char) -> c_int;
    fn sqlite3_step(stmt: *mut c_void) -> c_int;
    fn sqlite3_finalize(stmt: *mut c_void) -> c_int;
    fn sqlite3_column_int64(stmt: *mut c_void, column: c_int) -> i64;
    fn sqlite3_column_int(stmt: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_text(stmt: *mut c_void, column: c_int) -> *const c_char;
}

struct Database(*mut c_void);
impl Drop for Database {
    fn drop(&mut self) { unsafe { sqlite3_close(self.0); } }
}
struct Statement(*mut c_void);
impl Drop for Statement {
    fn drop(&mut self) { unsafe { sqlite3_finalize(self.0); } }
}

unsafe fn rows(db: &Database, sql: &'static [u8], mut visit: impl FnMut(*mut c_void)) -> bool {
    let mut raw = ptr::null_mut();
    let status = sqlite3_prepare_v2(db.0, sql.as_ptr().cast(), -1, &mut raw, ptr::null_mut());
    if raw.is_null() { return false; }
    let statement = Statement(raw);
    if status != 0 { return false; }
    loop {
        match sqlite3_step(statement.0) {
            100 => visit(statement.0),
            101 => return true,
            _ => return false,
        }
    }
}
unsafe fn text(stmt: *mut c_void, column: c_int) -> Option<Vec<u8>> {
    let value = sqlite3_column_text(stmt, column);
    if value.is_null() { None } else { Some(CStr::from_ptr(value).to_bytes().to_vec()) }
}

/// Emits bare apps (0), folder start (1), folder apps (2), and folder end (3).
#[no_mangle]
pub unsafe extern "C" fn launchpad_import_legacy(
    path: *const c_char,
    context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, c_int, *const u8, usize)>,
) -> c_int {
    if path.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let mut raw = ptr::null_mut();
    let status = sqlite3_open_v2(path, &mut raw, 1, ptr::null());
    if raw.is_null() { return 0; }
    let db = Database(raw);
    if status != 0 { return 0; }

    let mut root = None;
    let mut children: HashMap<i64, Vec<(i64, i32)>> = HashMap::new();
    if !rows(&db, b"SELECT rowid, uuid, parent_id, ordering FROM items\0", |stmt| {
        let id = sqlite3_column_int64(stmt, 0);
        let uuid = sqlite3_column_text(stmt, 1);
        if root.is_none() && !uuid.is_null() && CStr::from_ptr(uuid).to_bytes() == b"ROOTPAGE" { root = Some(id); }
        children.entry(sqlite3_column_int64(stmt, 2)).or_default().push((id, sqlite3_column_int(stmt, 3)));
    }) { return 0; }
    let mut apps = HashMap::new();
    if !rows(&db, b"SELECT item_id, bundleid FROM apps\0", |stmt| {
        if let Some(value) = text(stmt, 1) { apps.insert(sqlite3_column_int64(stmt, 0), value); }
    }) { return 0; }
    let mut folders = HashMap::new();
    if !rows(&db, b"SELECT item_id, title FROM groups\0", |stmt| {
        if let Some(value) = text(stmt, 1) { folders.insert(sqlite3_column_int64(stmt, 0), value); }
    }) { return 0; }
    let Some(root) = root else { return 1 };
    for items in children.values_mut() { items.sort_by_key(|item| item.1); }
    let emit = |kind, value: &[u8]| callback(context, kind, value.as_ptr(), value.len());
    enum Walk { Node(i64, bool), FolderEnd }
    let mut visited = HashSet::new();
    let mut stack = vec![Walk::Node(root, false)];
    while let Some(entry) = stack.pop() {
        let (id, mut inside_folder) = match entry {
            Walk::FolderEnd => { emit(3, &[]); continue; }
            Walk::Node(id, inside) => (id, inside),
        };
        if !visited.insert(id) { continue; }
        if id != root {
            if let Some(value) = apps.get(&id) {
                emit(if inside_folder { 2 } else { 0 }, value);
                continue;
            }
            if !inside_folder {
                if let Some(value) = folders.get(&id) {
                    emit(1, value);
                    stack.push(Walk::FolderEnd);
                    inside_folder = true;
                }
            }
        }
        if let Some(items) = children.get(&id) {
            for &(child, _) in items.iter().rev() {
                stack.push(Walk::Node(child, inside_folder));
            }
        }
    }
    1
}
