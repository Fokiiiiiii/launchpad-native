
/// Returns a search tier, or -1 when no field matches.
#[no_mangle]
pub unsafe extern "C" fn launchpad_search_tier(bytes: *const u8, length: usize) -> i32 {
    if bytes.is_null() { return -1; }
    let mut input = std::slice::from_raw_parts(bytes, length);
    let mut fields = Vec::with_capacity(12);
    for _ in 0..12 {
        if input.len() < 4 { return -1; }
        let size = u32::from_le_bytes([input[0], input[1], input[2], input[3]]) as usize;
        input = &input[4..];
        if input.len() < size { return -1; }
        let Ok(field) = std::str::from_utf8(&input[..size]) else { return -1; };
        fields.push(field);
        input = &input[size..];
    }
    let q = fields[0];
    let (name, original, alias, reading, reading_initials, initials) =
        (fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]);
    let names = [name, original, alias];
    if names.iter().any(|s| !s.is_empty() && *s == q) { return 0; }
    if !reading.is_empty() && reading == q { return 1; }
    if names.iter().any(|s| !s.is_empty() && s.starts_with(q)) { return 2; }
    if !reading.is_empty() && (reading.starts_with(q) || reading_initials.starts_with(q)) { return 3; }
    if fields[10].split('\0').any(|w| !w.is_empty() && w.starts_with(q)) { return 4; }
    if !reading.is_empty() && fields[11].split('\0').any(|w| !w.is_empty() && w.starts_with(q)) { return 5; }
    if !initials.is_empty() && initials.starts_with(q) { return 6; }
    if names.iter().any(|s| !s.is_empty() && s.contains(q)) { return 7; }
    if !reading.is_empty() && reading.contains(q) { return 8; }
    if fields[7..10].iter().any(|s| s.contains(q)) { return 9; }
    let candidates = [name, original, alias, reading];
    if q.is_ascii() && candidates.iter().all(|value| value.is_ascii()) {
        let wanted: Vec<u8> = q.bytes().filter(|byte| byte.is_ascii_alphanumeric()).collect();
        if wanted.is_empty() { return -1; }
        for text in candidates {
            let mut index = 0;
            for byte in text.bytes().filter(|byte| byte.is_ascii_alphanumeric()) {
                if byte == wanted[index] {
                    index += 1;
                    if index == wanted.len() { return 10; }
                }
            }
        }
        return -1;
    }
    // Swift supplies grapheme-aware subsequence matching for other scripts.
    -2
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run(fields: [&str; 12]) -> i32 {
        let mut bytes = Vec::new();
        for field in fields {
            bytes.extend_from_slice(&(field.len() as u32).to_le_bytes());
            bytes.extend_from_slice(field.as_bytes());
        }
        unsafe { launchpad_search_tier(bytes.as_ptr(), bytes.len()) }
    }
    #[test]
    fn ascii_fuzzy_matching_preserves_the_ordered_subsequence_rule() {
        let mut fields = [""; 12];
        fields[0] = "vsce";
        fields[1] = "visual studio code";
        assert_eq!(run(fields), 10);
        fields[0] = "zz";
        assert_eq!(run(fields), -1);
        fields[0] = "---";
        assert_eq!(run(fields), -1);
        fields[0] = "め";
        fields[1] = "メモ";
        assert_eq!(run(fields), -2);
    }
}
