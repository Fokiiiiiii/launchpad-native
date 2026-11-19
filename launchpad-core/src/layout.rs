use std::ffi::c_void;

fn reorder(counts: &[usize], selected: &[u8], leader: usize, target: usize, slot: usize, capacity: usize) -> Option<(Vec<usize>, Vec<usize>, usize)> {
    if counts.is_empty() || target >= counts.len() || capacity == 0 || leader >= selected.len() || selected[leader] != 1 || selected.iter().any(|value| *value > 1) { return None; }
    let total = counts.iter().try_fold(0_usize, |sum, value| sum.checked_add(*value))?;
    if total != selected.len() || total > 1_000_000 || counts.len() > 100_000 { return None; }
    let mut next = 0;
    let mut pages: Vec<Vec<usize>> = counts.iter().map(|count| { let start = next; next += count; (start..next).collect() }).collect();
    let destination: Vec<usize> = pages[target].iter().copied().filter(|item| *item != leader).collect();
    let slot = slot.min(destination.len());
    let before = destination[..slot].iter().filter(|item| selected[**item] == 1).count();
    let chosen: Vec<usize> = (0..total).filter(|index| selected[*index] == 1).collect();
    for page in &mut pages { page.retain(|item| selected[*item] == 0); }
    let insertion = slot.saturating_sub(before).min(pages[target].len());
    pages[target].splice(insertion..insertion, chosen);
    let mut index = target;
    while index < pages.len() && pages[index].len() > capacity {
        let overflow = pages[index].split_off(capacity);
        if index + 1 == pages.len() { pages.push(overflow); }
        else { pages[index + 1].splice(0..0, overflow); }
        index += 1;
    }
    let result_page = target - pages[..target].iter().filter(|page| page.is_empty()).count();
    pages.retain(|page| !page.is_empty());
    let lengths = pages.iter().map(Vec::len).collect();
    let order = pages.into_iter().flatten().collect();
    Some((order, lengths, result_page))
}

/// Calls back synchronously with a permutation of the original item indices.
#[no_mangle]
pub unsafe extern "C" fn launchpad_layout_reorder(
    counts: *const usize, page_count: usize, selected: *const u8, item_count: usize,
    leader: usize, target: usize, slot: usize, capacity: usize, context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, *const usize, usize, *const usize, usize, usize)>,
) -> i32 {
    if counts.is_null() || selected.is_null() || page_count > 100_000 || item_count > 1_000_000 { return 0; }
    let Some(callback) = callback else { return 0 };
    let counts = std::slice::from_raw_parts(counts, page_count);
    let selected = std::slice::from_raw_parts(selected, item_count);
    let Some((order, lengths, page)) = reorder(counts, selected, leader, target, slot, capacity) else { return 0 };
    callback(context, order.as_ptr(), order.len(), lengths.as_ptr(), lengths.len(), page);
    1
}

#[cfg(test)]
fn move_one(counts: &[usize], source: usize, source_index: usize, target: usize, slot: usize, capacity: usize) -> Option<(Vec<usize>, Vec<usize>)> {
    if source >= counts.len() || source_index >= counts[source] || target >= 100_000 || capacity == 0 { return None; }
    let total = counts.iter().try_fold(0_usize, |sum, value| sum.checked_add(*value))?;
    if total > 1_000_000 || counts.len() > 100_000 { return None; }
    let mut next = 0;
    let mut pages: Vec<Vec<usize>> = counts.iter().map(|count| { let start = next; next += count; (start..next).collect() }).collect();
    let item = pages[source].remove(source_index);
    while pages.len() <= target { pages.push(Vec::new()); }
    let mut slot = slot.min(pages[target].len());
    if pages[target].len() >= capacity { slot = slot.min(capacity - 1); }
    pages[target].insert(slot, item);
    let mut page = target;
    while page < pages.len() && pages[page].len() > capacity {
        let overflow = pages[page].split_off(capacity);
        if page + 1 == pages.len() { pages.push(overflow); }
        else { pages[page + 1].splice(0..0, overflow); }
        page += 1;
    }
    let lengths = pages.iter().map(Vec::len).collect();
    let order = pages.into_iter().flatten().collect();
    Some((order, lengths))
}


fn overflow_plan(sizes: &mut Vec<usize>, start: usize, capacity: usize) -> Option<Vec<usize>> {
    if capacity == 0 || sizes.len() > 100_000 { return None; }
    if sizes.iter().try_fold(0_usize, |sum, value| sum.checked_add(*value))? > 1_000_000 { return None; }
    let mut actions = Vec::new();
    let mut page = start;
    while page < sizes.len() && sizes[page] > capacity {
        let overflow = sizes[page] - capacity;
        sizes[page] = capacity;
        if page + 1 == sizes.len() { sizes.push(0); }
        sizes[page + 1] = sizes[page + 1].checked_add(overflow)?;
        actions.push(page);
        actions.push(overflow);
        page += 1;
    }
    Some(actions)
}

fn move_plan(counts: &[usize], source: usize, source_index: usize, target: usize, slot: usize, capacity: usize) -> Option<(usize, Vec<usize>)> {
    if source >= counts.len() || source_index >= counts[source] || target >= 100_000 || capacity == 0 || counts.len() > 100_000 { return None; }
    let total = counts.iter().try_fold(0_usize, |sum, value| sum.checked_add(*value))?;
    if total > 1_000_000 { return None; }
    let mut sizes = counts.to_vec();
    sizes[source] -= 1;
    sizes.resize(sizes.len().max(target + 1), 0);
    let mut insertion = slot.min(sizes[target]);
    if sizes[target] >= capacity { insertion = insertion.min(capacity - 1); }
    sizes[target] += 1;
    let actions = overflow_plan(&mut sizes, target, capacity)?;
    Some((insertion, actions))
}

/// Returns the insertion position and ordered page overflow operations.
#[no_mangle]
pub unsafe extern "C" fn launchpad_layout_move_one(
    counts: *const usize, page_count: usize, source: usize, source_index: usize,
    target: usize, slot: usize, capacity: usize, context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, usize, *const usize, usize)>,
) -> i32 {
    if counts.is_null() || page_count > 100_000 { return 0; }
    let Some(callback) = callback else { return 0 };
    let counts = std::slice::from_raw_parts(counts, page_count);
    let Some((insertion, actions)) = move_plan(counts, source, source_index, target, slot, capacity) else { return 0 };
    callback(context, insertion, actions.as_ptr(), actions.len());
    1
}

/// Returns ordered page-overflow operations without moving application data.
#[no_mangle]
pub unsafe extern "C" fn launchpad_layout_overflow(
    counts: *const usize, page_count: usize, start: usize, capacity: usize, context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, *const usize, usize)>,
) -> i32 {
    if counts.is_null() || page_count > 100_000 { return 0; }
    let Some(callback) = callback else { return 0 };
    let mut sizes = std::slice::from_raw_parts(counts, page_count).to_vec();
    let Some(actions) = overflow_plan(&mut sizes, start, capacity) else { return 0 };
    callback(context, actions.as_ptr(), actions.len());
    1
}

/// Calculates page boundaries for a stable, compact ordering.
#[no_mangle]
pub unsafe extern "C" fn launchpad_layout_repack(
    item_count: usize, capacity: usize, context: *mut c_void,
    callback: Option<unsafe extern "C" fn(*mut c_void, *const usize, usize, *const usize, usize, usize)>,
) -> i32 {
    if item_count > 1_000_000 || capacity == 0 { return 0; }
    let Some(callback) = callback else { return 0 };
    let order: Vec<usize> = (0..item_count).collect();
    let lengths: Vec<usize> = if item_count == 0 { vec![0] } else {
        let full = item_count / capacity;
        let remainder = item_count % capacity;
        let mut sizes = vec![capacity; full];
        if remainder > 0 { sizes.push(remainder); }
        sizes
    };
    callback(context, order.as_ptr(), order.len(), lengths.as_ptr(), lengths.len(), 0);
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn moves_multiple_items_without_losing_order() {
        assert_eq!(reorder(&[4], &[1, 0, 1, 0], 0, 0, 3, 4), Some((vec![1, 3, 0, 2], vec![4], 0)));
        assert_eq!(reorder(&[2, 2], &[1, 1, 0, 0], 0, 1, 0, 2), Some((vec![0, 1, 2, 3], vec![2, 2], 0)));
        assert_eq!(reorder(&[2, 2], &[0, 1, 0, 1], 1, 0, 0, 2), Some((vec![1, 3, 0, 2], vec![2, 2], 0)));
    }

    #[test]
    fn single_move_preserves_capacity_and_empty_page_semantics() {
        assert_eq!(move_one(&[4, 2], 1, 1, 0, 0, 4), Some((vec![5, 0, 1, 2, 3, 4], vec![4, 2])));
        assert_eq!(move_one(&[4, 1], 1, 0, 0, 4, 4), Some((vec![0, 1, 2, 4, 3], vec![4, 1])));
        assert_eq!(move_one(&[1], 0, 0, 1, 0, 2), Some((vec![0], vec![0, 1])));
        assert!(move_one(&[1], 0, 1, 0, 0, 2).is_none());
    }

    #[test]
    fn single_move_plan_matches_original_for_small_layouts() {
        for a in 0..=3 { for b in 0..=3 { for c in 0..=3 {
            let counts = [a, b, c];
            for source in 0..3 { for source_index in 0..counts[source] {
                for target in 0..4 { for slot in 0..=4 { for capacity in 1..=3 {
                    let expected = move_one(&counts, source, source_index, target, slot, capacity).unwrap();
                    let (insertion, actions) = move_plan(&counts, source, source_index, target, slot, capacity).unwrap();
                    let mut next = 0;
                    let mut pages: Vec<Vec<usize>> = counts.iter().map(|count| { let start = next; next += count; (start..next).collect() }).collect();
                    let item = pages[source].remove(source_index);
                    while pages.len() <= target { pages.push(Vec::new()); }
                    pages[target].insert(insertion, item);
                    for pair in actions.chunks_exact(2) {
                        let page = pair[0];
                        let split = pages[page].len() - pair[1];
                        let overflow = pages[page].split_off(split);
                        if page + 1 == pages.len() { pages.push(overflow); }
                        else { pages[page + 1].splice(0..0, overflow); }
                    }
                    let lengths = pages.iter().map(Vec::len).collect();
                    let order = pages.into_iter().flatten().collect();
                    assert_eq!((order, lengths), expected);
                } } }
            } }
        } } }
    }

    #[test]
    fn overflow_plan_matches_single_item_cascade() {
        for a in 0..=5 { for b in 0..=5 { for c in 0..=5 {
            let counts = [a, b, c];
            for start in 0..=3 { for capacity in 1..=4 {
                let mut next = 0;
                let initial: Vec<Vec<usize>> = counts.iter().map(|count| {
                    let begin = next; next += count; (begin..next).collect()
                }).collect();
                let mut expected = initial.clone();
                let mut page = start;
                while page < expected.len() && expected[page].len() > capacity {
                    let item = expected[page].pop().unwrap();
                    if page + 1 == expected.len() { expected.push(vec![item]); }
                    else { expected[page + 1].insert(0, item); }
                    if expected[page].len() <= capacity { page += 1; }
                }
                let mut sizes = counts.to_vec();
                let actions = overflow_plan(&mut sizes, start, capacity).unwrap();
                let mut actual = initial;
                for pair in actions.chunks_exact(2) {
                    let page = pair[0];
                    let split = actual[page].len() - pair[1];
                    let overflow = actual[page].split_off(split);
                    if page + 1 == actual.len() { actual.push(overflow); }
                    else { actual[page + 1].splice(0..0, overflow); }
                }
                assert_eq!(actual, expected);
            } }
        } } }
        assert!(overflow_plan(&mut vec![1], 0, 0).is_none());
    }

    #[test]
    fn repack_callback_handles_empty_and_partial_pages() {
        unsafe extern "C" fn capture(context: *mut c_void, order: *const usize, n: usize, lengths: *const usize, pages: usize, _: usize) {
            let output = &mut *(context as *mut (Vec<usize>, Vec<usize>));
            output.0 = std::slice::from_raw_parts(order, n).to_vec();
            output.1 = std::slice::from_raw_parts(lengths, pages).to_vec();
        }
        let mut output: (Vec<usize>, Vec<usize>) = (Vec::new(), Vec::new());
        let context = (&mut output as *mut (Vec<usize>, Vec<usize>)).cast();
        assert_eq!(unsafe { launchpad_layout_repack(5, 2, context, Some(capture)) }, 1);
        assert_eq!(output, (vec![0, 1, 2, 3, 4], vec![2, 2, 1]));
        assert_eq!(unsafe { launchpad_layout_repack(0, 2, context, Some(capture)) }, 1);
        assert_eq!(output, (vec![], vec![0]));
        assert_eq!(unsafe { launchpad_layout_repack(5, 0, context, Some(capture)) }, 0);
    }
    #[test]
    fn rejects_invalid_input_without_mutation() {
        assert!(reorder(&[2], &[1], 0, 0, 0, 2).is_none());
        assert!(reorder(&[1], &[0], 0, 0, 0, 2).is_none());
        assert!(reorder(&[1], &[1], 0, 1, 0, 2).is_none());
        assert!(reorder(&[1], &[1], 0, 0, 0, 0).is_none());
    }

    #[test]
    fn reorder_matches_previous_policy_for_small_page_layouts() {
        for a in 0..=3 { for b in 0..=3 { for c in 0..=3 {
            let counts = [a, b, c];
            let total = a + b + c;
            if total == 0 { continue; }
            for mask in 1..(1_usize << total) {
                let selected: Vec<u8> = (0..total).map(|index| ((mask >> index) & 1) as u8).collect();
                let leader = selected.iter().position(|value| *value == 1).unwrap();
                for target in 0..3 { for slot in 0..=4 { for capacity in 1..=3 {
                    let mut next = 0;
                    let mut pages: Vec<Vec<usize>> = counts.iter().map(|count| { let start = next; next += count; (start..next).collect() }).collect();
                    let without_leader: Vec<usize> = pages[target].iter().copied().filter(|item| *item != leader).collect();
                    let original_slot = slot.min(without_leader.len());
                    let preceding = without_leader[..original_slot].iter().filter(|item| selected[**item] == 1).count();
                    let ordered: Vec<usize> = pages.iter().flatten().copied().filter(|item| selected[*item] == 1).collect();
                    for page in &mut pages { page.retain(|item| selected[*item] == 0); }
                    let insertion = original_slot.saturating_sub(preceding).min(pages[target].len());
                    pages[target].splice(insertion..insertion, ordered);
                    let mut page = target;
                    while page < pages.len() && pages[page].len() > capacity {
                        let overflow = pages[page].pop().unwrap();
                        if page + 1 == pages.len() { pages.push(vec![overflow]); }
                        else { pages[page + 1].insert(0, overflow); }
                        if pages[page].len() <= capacity { page += 1; }
                    }
                    let result_page = target - pages[..target].iter().filter(|page| page.is_empty()).count();
                    pages.retain(|page| !page.is_empty());
                    let lengths = pages.iter().map(Vec::len).collect();
                    let order = pages.into_iter().flatten().collect();
                    assert_eq!(reorder(&counts, &selected, leader, target, slot, capacity), Some((order, lengths, result_page)));
                } } }
            }
        } } }
    }
}
