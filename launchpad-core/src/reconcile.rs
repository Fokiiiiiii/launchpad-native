use std::collections::HashMap;
use std::ffi::c_void;

struct Reader<'a> { bytes: &'a [u8] }
impl<'a> Reader<'a> {
    fn number(&mut self) -> Option<u32> {
        let (head, tail) = self.bytes.split_at_checked(4)?;
        self.bytes = tail;
        Some(u32::from_le_bytes(head.try_into().ok()?))
    }
    fn string(&mut self, optional: bool) -> Option<Option<&'a str>> {
        let size = self.number()?;
        if size == u32::MAX { return if optional { Some(None) } else { None }; }
        let (head, tail) = self.bytes.split_at_checked(size as usize)?;
        self.bytes = tail;
        Some(Some(std::str::from_utf8(head).ok()?))
    }
    fn fingerprint(&mut self) -> Option<(&'a str, Option<&'a str>)> { Some((self.string(false)??, self.string(true)?)) }
}

fn matches(bytes: &[u8]) -> Option<Vec<u32>> {
    let mut reader = Reader { bytes };
    let old_count = reader.number()? as usize;
    let new_count = reader.number()? as usize;
    if old_count.checked_add(new_count)? > reader.bytes.len() / 8 { return None; }
    let mut fingerprints = HashMap::with_capacity(old_count);
    for index in 0..old_count {
        let key = reader.fingerprint()?;
        let entry = fingerprints.entry(key).or_insert((0_usize, index, 0_usize, 0_usize));
        entry.0 += 1;
    }
    for index in 0..new_count {
        let key = reader.fingerprint()?;
        if let Some(entry) = fingerprints.get_mut(&key) {
            entry.2 += 1;
            entry.3 = index;
        }
    }
    if !reader.bytes.is_empty() { return None; }
    let mut pairs = Vec::new();
    for &(old_count, old_index, new_count, new_index) in fingerprints.values() {
        if old_count == 1 && new_count == 1 {
            pairs.push((u32::try_from(old_index).ok()?, u32::try_from(new_index).ok()?));
        }
    }
    pairs.sort_unstable_by_key(|pair| pair.0);
    Some(pairs.into_iter().flat_map(|(old, new)| [old, new]).collect())
}

/// Matches only unambiguous bundle and signing-team pairs.
#[no_mangle]
pub unsafe extern "C" fn launchpad_match_moved_apps(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u32, usize)>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(pairs) = matches(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, pairs.as_ptr(), pairs.len());
    1
}

fn ordered_indices(bytes: &[u8]) -> Option<Vec<u32>> {
    let mut reader = Reader { bytes };
    let record_count = reader.number()? as usize;
    let placed_count = reader.number()? as usize;
    if record_count.checked_add(placed_count)? > reader.bytes.len() / 4 { return None; }
    let mut indices = HashMap::with_capacity(record_count);
    for index in 0..record_count {
        let id = reader.string(false)??;
        if indices.insert(id, u32::try_from(index).ok()?).is_some() { return None; }
    }
    let mut seen = vec![false; record_count];
    let mut output = Vec::with_capacity(record_count);
    for _ in 0..placed_count {
        let id = reader.string(false)??;
        if let Some(&index) = indices.get(id) {
            let seen = &mut seen[index as usize];
            if !*seen { output.push(index); *seen = true; }
        }
    }
    if !reader.bytes.is_empty() { return None; }
    for (index, was_seen) in seen.into_iter().enumerate() {
        if !was_seen { output.push(u32::try_from(index).ok()?); }
    }
    Some(output)
}

/// Returns record indices in layout order, then the remaining input order.
#[no_mangle]
pub unsafe extern "C" fn launchpad_order_records(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u32, usize)>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(indices) = ordered_indices(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, indices.as_ptr(), indices.len());
    1
}

fn merged_indices(bytes: &[u8]) -> Option<Vec<u32>> {
    let mut reader = Reader { bytes };
    let count = reader.number()? as usize;
    if count > reader.bytes.len() / 5 { return None; }
    let mut chosen: HashMap<&str, u32> = HashMap::with_capacity(count.min(1024));
    for index in 0..count {
        let (&mode, rest) = reader.bytes.split_first()?;
        reader.bytes = rest;
        let id = reader.string(false)??;
        let index = u32::try_from(index).ok()?;
        match mode {
            0 => { chosen.insert(id, index); }
            1 => { chosen.entry(id).or_insert(index); }
            _ => return None,
        }
    }
    if !reader.bytes.is_empty() { return None; }
    let mut output: Vec<u32> = chosen.into_values().collect();
    output.sort_unstable();
    Some(output)
}

/// Selects the latest scanned record while retaining unreadable prior records.
#[no_mangle]
pub unsafe extern "C" fn launchpad_merge_catalog(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u32, usize)>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(indices) = merged_indices(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, indices.as_ptr(), indices.len());
    1
}

fn unplaced_indices(bytes: &[u8]) -> Option<Vec<u32>> {
    use std::collections::HashSet;
    let mut reader = Reader { bytes };
    let record_count = reader.number()? as usize;
    let hidden_count = reader.number()? as usize;
    let placed_count = reader.number()? as usize;
    if record_count.checked_add(hidden_count)?.checked_add(placed_count)? > reader.bytes.len() / 4 { return None; }
    let mut excluded = HashSet::with_capacity(hidden_count.saturating_add(placed_count).min(4096));
    for _ in 0..hidden_count.checked_add(placed_count)? {
        excluded.insert(reader.string(false)??);
    }
    let mut output = Vec::new();
    for index in 0..record_count {
        let (&eligible, rest) = reader.bytes.split_first()?;
        reader.bytes = rest;
        let id = reader.string(false)??;
        match eligible {
            0 => {}
            1 if !excluded.contains(id) => output.push(u32::try_from(index).ok()?),
            1 => {}
            _ => return None,
        }
    }
    if !reader.bytes.is_empty() { return None; }
    Some(output)
}

/// Selects eligible records that are neither hidden nor already placed.
#[no_mangle]
pub unsafe extern "C" fn launchpad_unplaced_records(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u32, usize)>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(indices) = unplaced_indices(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, indices.as_ptr(), indices.len());
    1
}

fn first_missing_indices(bytes: &[u8]) -> Option<Vec<u32>> {
    use std::collections::HashSet;
    let mut reader = Reader { bytes };
    let existing = reader.number()? as usize;
    let candidates = reader.number()? as usize;
    if existing.checked_add(candidates)? > reader.bytes.len() / 4 { return None; }
    let mut seen = HashSet::with_capacity(existing.min(4096));
    for _ in 0..existing { seen.insert(reader.string(false)??); }
    let mut output = Vec::new();
    for index in 0..candidates {
        let id = reader.string(false)??;
        if seen.insert(id) { output.push(u32::try_from(index).ok()?); }
    }
    if !reader.bytes.is_empty() { return None; }
    Some(output)
}

/// Finds the first occurrence of IDs missing from the existing date map.
#[no_mangle]
pub unsafe extern "C" fn launchpad_missing_dates(bytes: *const u8, length: usize, context: *mut c_void, callback: Option<unsafe extern "C" fn(*mut c_void, *const u32, usize)>) -> i32 {
    if bytes.is_null() || length > isize::MAX as usize { return 0; }
    let Some(callback) = callback else { return 0 };
    let Some(indices) = first_missing_indices(std::slice::from_raw_parts(bytes, length)) else { return 0 };
    callback(context, indices.as_ptr(), indices.len());
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input(old: &[(&str, Option<&str>)], new: &[(&str, Option<&str>)]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&(old.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&(new.len() as u32).to_le_bytes());
        for (bundle, team) in old.iter().chain(new) {
            bytes.extend_from_slice(&(bundle.len() as u32).to_le_bytes());
            bytes.extend_from_slice(bundle.as_bytes());
            match team {
                Some(team) => { bytes.extend_from_slice(&(team.len() as u32).to_le_bytes()); bytes.extend_from_slice(team.as_bytes()); }
                None => bytes.extend_from_slice(&u32::MAX.to_le_bytes()),
            }
        }
        bytes
    }
    #[test]
    fn matches_only_unique_exact_fingerprints() {
        let bytes = input(&[("a", None), ("b", Some("T")), ("ambiguous", None)], &[("b", Some("T")), ("a", None), ("ambiguous", None), ("ambiguous", None)]);
        assert_eq!(matches(&bytes), Some(vec![0, 1, 1, 0]));
        assert!(matches(&bytes[..bytes.len() - 1]).is_none());
        assert_eq!(matches(&input(&[("a", None)], &[("a", Some(""))])), Some(vec![]));
    }

    #[test]
    fn ordering_keeps_placed_order_and_appends_unplaced_records() {
        fn packet(records: &[&str], placed: &[&str]) -> Vec<u8> {
            let mut data = Vec::new();
            data.extend_from_slice(&(records.len() as u32).to_le_bytes());
            data.extend_from_slice(&(placed.len() as u32).to_le_bytes());
            for id in records.iter().chain(placed) {
                data.extend_from_slice(&(id.len() as u32).to_le_bytes());
                data.extend_from_slice(id.as_bytes());
            }
            data
        }
        assert_eq!(ordered_indices(&packet(&["a", "b", "c", "d"], &["c", "missing", "a", "c"])), Some(vec![2, 0, 1, 3]));
        assert_eq!(ordered_indices(&packet(&[], &["missing"])), Some(vec![]));
        assert!(ordered_indices(&packet(&["a", "a"], &[])).is_none());
        let malformed = packet(&["a"], &["a"]);
        assert!(ordered_indices(&malformed[..malformed.len() - 1]).is_none());
    }

    #[test]
    fn unplaced_matches_reference_across_flags_and_exclusions() {
        let ids = ["a", "b", "c", "d"];
        for eligibility in 0..16_u8 {
            for hidden in 0..16_u8 {
                for placed in 0..16_u8 {
                    let mut data = Vec::new();
                    data.extend_from_slice(&4_u32.to_le_bytes());
                    data.extend_from_slice(&(hidden.count_ones()).to_le_bytes());
                    data.extend_from_slice(&(placed.count_ones()).to_le_bytes());
                    let mut put = |id: &str| { data.extend_from_slice(&(id.len() as u32).to_le_bytes()); data.extend_from_slice(id.as_bytes()); };
                    for (index, id) in ids.iter().enumerate() { if hidden & (1 << index) != 0 { put(id); } }
                    for (index, id) in ids.iter().enumerate() { if placed & (1 << index) != 0 { put(id); } }
                    for (index, id) in ids.iter().enumerate() {
                        data.push(u8::from(eligibility & (1 << index) != 0));
                        data.extend_from_slice(&(id.len() as u32).to_le_bytes());
                        data.extend_from_slice(id.as_bytes());
                    }
                    let expected: Vec<u32> = (0..4).filter(|index| eligibility & (1 << index) != 0 && (hidden | placed) & (1 << index) == 0).collect();
                    assert_eq!(unplaced_indices(&data), Some(expected));
                    assert!(unplaced_indices(&data[..data.len() - 1]).is_none());
                }
            }
        }
    }

    #[test]
    fn first_missing_preserves_order_and_ignores_duplicate_candidates() {
        use std::collections::HashSet;
        let choices = ["a", "b", "c"];
        for mut case in 0..3_usize.pow(5) {
            let candidates: Vec<_> = (0..5).map(|_| { let value = choices[case % 3]; case /= 3; value }).collect();
            for mask in 0..8_u8 {
                let existing: Vec<_> = choices.iter().enumerate().filter(|(index, _)| mask & (1 << index) != 0).map(|(_, id)| *id).collect();
                let mut packet = Vec::new();
                packet.extend_from_slice(&(existing.len() as u32).to_le_bytes());
                packet.extend_from_slice(&(candidates.len() as u32).to_le_bytes());
                for id in existing.iter().chain(&candidates) {
                    packet.extend_from_slice(&(id.len() as u32).to_le_bytes());
                    packet.extend_from_slice(id.as_bytes());
                }
                let mut seen: HashSet<_> = existing.iter().copied().collect();
                let expected: Vec<_> = candidates.iter().enumerate().filter_map(|(index, id)| seen.insert(*id).then_some(index as u32)).collect();
                assert_eq!(first_missing_indices(&packet), Some(expected));
                assert!(first_missing_indices(&packet[..packet.len() - 1]).is_none());
            }
        }
    }

    #[test]
    fn catalog_merge_matches_upsert_and_carry_reference() {
        let ids = ["a", "b", "c"];
        for count in 0..=6 {
            for mut case in 0..6_usize.pow(count as u32) {
                let mut data = Vec::new();
                data.extend_from_slice(&(count as u32).to_le_bytes());
                let mut expected = HashMap::new();
                for index in 0..count {
                    let choice = case % 6; case /= 6;
                    let id = ids[choice % 3];
                    let mode = (choice / 3) as u8;
                    data.push(mode);
                    data.extend_from_slice(&(id.len() as u32).to_le_bytes());
                    data.extend_from_slice(id.as_bytes());
                    if mode == 0 { expected.insert(id, index as u32); }
                    else { expected.entry(id).or_insert(index as u32); }
                }
                let mut values: Vec<u32> = expected.into_values().collect();
                values.sort_unstable();
                assert_eq!(merged_indices(&data), Some(values));
                if count > 0 { assert!(merged_indices(&data[..data.len() - 1]).is_none()); }
            }
        }
    }

    #[test]
    fn ordering_matches_reference_for_missing_and_repeated_ids() {
        use std::collections::HashSet;
        let records = ["a", "b", "c", "d"];
        let choices = ["a", "b", "c", "d", "missing"];
        for mut case in 0..5_usize.pow(5) {
            let mut placed = Vec::new();
            for _ in 0..5 { placed.push(choices[case % 5]); case /= 5; }
            let mut data = Vec::new();
            data.extend_from_slice(&(records.len() as u32).to_le_bytes());
            data.extend_from_slice(&(placed.len() as u32).to_le_bytes());
            for id in records.iter().chain(&placed) { data.extend_from_slice(&(id.len() as u32).to_le_bytes()); data.extend_from_slice(id.as_bytes()); }
            let mut seen = HashSet::new();
            let mut expected = Vec::new();
            for id in &placed { if seen.insert(*id) { if let Some(index) = records.iter().position(|record| record == id) { expected.push(index as u32); } } }
            for (index, id) in records.iter().enumerate() { if seen.insert(*id) { expected.push(index as u32); } }
            assert_eq!(ordered_indices(&data), Some(expected));
        }
    }

    #[test]
    fn matches_reference_across_duplicate_combinations() {
        let choices = [("a", None), ("a", Some("")), ("b", Some("team"))];
        for old_len in 0..=4 { for new_len in 0..=4 {
            let old_cases = 3_usize.pow(old_len as u32);
            let new_cases = 3_usize.pow(new_len as u32);
            for old_case in 0..old_cases { for new_case in 0..new_cases {
                let mut value = old_case;
                let old: Vec<_> = (0..old_len).map(|_| { let item = choices[value % 3]; value /= 3; item }).collect();
                let mut value = new_case;
                let new: Vec<_> = (0..new_len).map(|_| { let item = choices[value % 3]; value /= 3; item }).collect();
                let mut expected = Vec::new();
                for (old_index, fingerprint) in old.iter().enumerate() {
                    if old.iter().filter(|item| *item == fingerprint).count() != 1 { continue; }
                    let candidates: Vec<_> = new.iter().enumerate().filter(|(_, item)| *item == fingerprint).map(|(index, _)| index).collect();
                    if candidates.len() == 1 { expected.extend_from_slice(&[old_index as u32, candidates[0] as u32]); }
                }
                assert_eq!(matches(&input(&old, &new)), Some(expected));
            } }
        } }
    }
}
