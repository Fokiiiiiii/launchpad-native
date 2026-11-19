use std::ffi::{c_char, c_void, CStr, OsStr};
use std::io::{BufRead, BufReader};
use std::os::unix::ffi::OsStrExt;
use std::process::{Command, Stdio};

/// Streams UTF-8 records synchronously, returning zero on launch or read failure.
#[no_mangle]
pub unsafe extern "C" fn launchpad_receipt_lines(
    program: *const c_char,
    context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>,
) -> i32 {
    if program.is_null() { return 0; }
    let Some(callback) = callback else { return 0 };
    let path = OsStr::from_bytes(CStr::from_ptr(program).to_bytes());
    let Ok(mut child) = Command::new(path).arg("--pkgs").stdout(Stdio::piped()).stderr(Stdio::null()).spawn() else { return 0 };
    let Some(stdout) = child.stdout.take() else { let _ = child.kill(); let _ = child.wait(); return 0 };
    let mut reader = BufReader::new(stdout);
    let mut bytes = Vec::new();
    let success = loop {
        let before = bytes.len();
        match reader.read_until(b'\n', &mut bytes) {
            Err(_) => break false,
            Ok(0) => {
                if std::str::from_utf8(&bytes).is_err() { break false; }
                if !bytes.is_empty() { callback(context, bytes.as_ptr(), bytes.len()); }
                break true;
            }
            Ok(_) => {
                let newline = bytes.last() == Some(&b'\n');
                let crlf = newline && bytes.len() >= 2 && bytes[bytes.len() - 2] == b'\r';
                if crlf { continue; }
                if newline { bytes.pop(); }
                if std::str::from_utf8(&bytes).is_err() { break false; }
                if !bytes.is_empty() { callback(context, bytes.as_ptr(), bytes.len()); }
                bytes.clear();
                if before == 0 && !newline { break true; }
            }
        }
    };
    drop(reader);
    if !success { let _ = child.kill(); }
    if child.wait().is_err() { return 0; }
    i32::from(success)
}
