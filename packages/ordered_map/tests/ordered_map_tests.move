// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for the B+ tree `ordered_map` against a sorted-vector reference.
///
/// The node size parameters are kept tiny so that a few dozen keys already force leaf and branch
/// splits, borrows between siblings, merges and root collapses. After every operation the tree is
/// compared with the reference on size, minimum key, leaf-chain iteration order, lookups and
/// `find_leaf`/`find_index` consistency.
#[test_only]
module ordered_map::ordered_map_tests;

use haneul::tx_context;
use ordered_map::ordered_map::{Self as om, Map};

// Smallest parameters `check_map_params` accepts: every node holds two to four kids and every
// leaf two to three entries.
const BRANCH_MIN: u64 = 2;
const BRANCHES_MERGE_MAX: u64 = 4;
const BRANCH_MAX: u64 = 4;
const LEAF_MIN: u64 = 2;
const LEAVES_MERGE_MAX: u64 = 3;
const LEAF_MAX: u64 = 3;

// === Reference: sorted keys with values ===

public struct Ref has drop { keys: vector<u128>, vals: vector<u64> }

fun ref_empty(): Ref {
    Ref { keys: vector[], vals: vector[] }
}

/// Index of the first key >= `key`.
fun ref_lower_bound(r: &Ref, key: u128): u64 {
    let mut i = 0;
    while (i < r.keys.length() && r.keys[i] < key) i = i + 1;
    i
}

fun ref_has(r: &Ref, key: u128): bool {
    let i = ref_lower_bound(r, key);
    i < r.keys.length() && r.keys[i] == key
}

fun ref_insert(r: &mut Ref, key: u128, val: u64) {
    let i = ref_lower_bound(r, key);
    assert!(i == r.keys.length() || r.keys[i] != key);
    r.keys.insert(key, i);
    r.vals.insert(val, i);
}

fun ref_remove(r: &mut Ref, key: u128): u64 {
    let i = ref_lower_bound(r, key);
    assert!(i < r.keys.length() && r.keys[i] == key);
    r.keys.remove(i);
    r.vals.remove(i)
}

/// Drops every key <= `key` (or < `key` when not inclusive).
fun ref_batch_drop(r: &mut Ref, key: u128, inclusive: bool) {
    while (!r.keys.is_empty() && (r.keys[0] < key || (inclusive && r.keys[0] == key))) {
        r.keys.remove(0);
        r.vals.remove(0);
    }
}

// === Invariants ===

fun new_map(ctx: &mut TxContext): Map<u64> {
    om::empty(
        BRANCH_MIN,
        BRANCHES_MERGE_MAX,
        BRANCH_MAX,
        LEAF_MIN,
        LEAVES_MERGE_MAX,
        LEAF_MAX,
        ctx,
    )
}

fun check(map: &Map<u64>, r: &Ref) {
    let n = r.keys.length();
    assert!(map.map_size() == n);
    assert!(map.is_empty() == (n == 0));
    if (n > 0) assert!(map.min_key() == r.keys[0]);

    // The leaf chain lists every entry in ascending key order, and each leaf's own binary
    // search finds its entries.
    let mut seen = 0;
    let mut leaf_ptr = map.first_leaf_ptr();
    let mut last_key = 0;
    while (leaf_ptr != 0) {
        let leaf = map.get_leaf(leaf_ptr);
        let size = leaf.size();
        // Every leaf but a lone root leaf respects the minimum fill.
        if (n > LEAF_MAX) assert!(size >= LEAF_MIN);
        assert!(size <= LEAF_MAX);
        let mut i = 0;
        while (i < size) {
            let (key, val) = leaf.elem(i);
            assert!(key == r.keys[seen] && *val == r.vals[seen]);
            assert!(seen == 0 || key > last_key);
            assert!(leaf.find_index(key) == i);
            assert!(map.find_leaf(key) == leaf_ptr);
            last_key = key;
            seen = seen + 1;
            i = i + 1;
        };
        leaf_ptr = leaf.next();
    };
    assert!(seen == n);

    let mut i = 0;
    while (i < n) {
        let key = r.keys[i];
        assert!(map.has_key(key));
        assert!(*map.borrow(key) == r.vals[i]);
        // Keys between two present keys are absent.
        if (i + 1 < n && r.keys[i + 1] > key + 1) assert!(!map.has_key(key + 1));
        i = i + 1;
    };
    if (n == 0 || r.keys[0] > 0) assert!(!map.has_key(0));
    assert!(!map.has_key(0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff));
}

fun insert_both(map: &mut Map<u64>, r: &mut Ref, key: u128, val: u64) {
    map.insert(key, val);
    ref_insert(r, key, val);
    check(map, r);
}

fun remove_both(map: &mut Map<u64>, r: &mut Ref, key: u128) {
    let val = map.remove(key);
    assert!(val == ref_remove(r, key));
    check(map, r);
}

// The full check walks the whole tree, so the bulk tests only run it every few operations.
const STRIDE: u64 = 5;

fun insert_bulk(map: &mut Map<u64>, r: &mut Ref, key: u128, val: u64, i: u64) {
    map.insert(key, val);
    ref_insert(r, key, val);
    if (i % STRIDE == 0) check(map, r);
}

fun remove_bulk(map: &mut Map<u64>, r: &mut Ref, key: u128, i: u64) {
    let val = map.remove(key);
    assert!(val == ref_remove(r, key));
    if (i % STRIDE == 0) check(map, r);
}

// === Basics ===

#[test]
fun empty_map() {
    let ctx = &mut tx_context::dummy();
    let map = new_map(ctx);
    check(&map, &ref_empty());
    map.destroy_empty();
}

#[test]
fun ascending_inserts_and_removes() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 1;
    while (k <= 60) {
        insert_bulk(&mut map, &mut r, k, (k as u64) * 10, (k as u64));
        k = k + 1;
    };
    // Values are mutable in place.
    *map.borrow_mut(7) = 700;
    *&mut r.vals[6] = 700;
    check(&map, &r);
    k = 1;
    while (k <= 60) {
        remove_bulk(&mut map, &mut r, k, (k as u64));
        k = k + 1;
    };
    check(&map, &r);
    map.destroy_empty();
}

#[test]
fun descending_inserts_and_removes_from_the_back() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 60;
    while (k >= 1) {
        insert_bulk(&mut map, &mut r, k * 1000, (k as u64), (k as u64));
        k = k - 1;
    };
    check(&map, &r);
    k = 60;
    while (k >= 1) {
        remove_bulk(&mut map, &mut r, k * 1000, (k as u64));
        k = k - 1;
    };
    check(&map, &r);
    map.destroy_empty();
}

#[test]
fun interleaved_inserts_fill_gaps() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 0;
    while (k < 40) {
        insert_bulk(&mut map, &mut r, k * 2 + 1, (k as u64), (k as u64));
        k = k + 1;
    };
    k = 0;
    while (k < 40) {
        insert_bulk(&mut map, &mut r, k * 2 + 2, (k as u64) + 100, (k as u64));
        k = k + 1;
    };
    check(&map, &r);
    // Remove the middle third, then everything.
    k = 27;
    while (k <= 54) {
        remove_bulk(&mut map, &mut r, k, (k as u64));
        k = k + 1;
    };
    check(&map, &r);
    let mut i = 0;
    while (!r.keys.is_empty()) {
        let key = r.keys[r.keys.length() / 2];
        remove_bulk(&mut map, &mut r, key, i);
        i = i + 1;
    };
    check(&map, &r);
    map.destroy_empty();
}

#[test]
fun try_remove_reports_absence() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 1;
    while (k <= 20) {
        insert_both(&mut map, &mut r, k, (k as u64));
        k = k + 1;
    };
    assert!(map.try_remove(21).is_none());
    assert!(map.try_remove(0).is_none());
    check(&map, &r);
    let removed = map.try_remove(10);
    assert!(removed.is_some() && removed.destroy_some() == 10);
    ref_remove(&mut r, 10);
    check(&map, &r);
    assert!(map.try_remove(10).is_none());
    check(&map, &r);
    k = 1;
    while (k <= 20) {
        if (k != 10) {
            assert!(map.try_remove(k).destroy_some() == (k as u64));
            ref_remove(&mut r, k);
            check(&map, &r);
        };
        k = k + 1;
    };
    map.destroy_empty();
}

#[test]
fun clear_and_drop() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 1;
    while (k <= 50) {
        insert_both(&mut map, &mut r, k * 3, (k as u64));
        k = k + 1;
    };
    map.clear();
    r = ref_empty();
    check(&map, &r);
    // The cleared map is usable again.
    insert_both(&mut map, &mut r, 5, 5);
    insert_both(&mut map, &mut r, 4, 4);
    om::drop(map);
}

// === batch_drop ===

#[test]
fun batch_drop_prefixes() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 1;
    while (k <= 64) {
        insert_both(&mut map, &mut r, k * 10, (k as u64));
        k = k + 1;
    };
    // Inclusive of an existing key.
    map.batch_drop(50, true);
    ref_batch_drop(&mut r, 50, true);
    check(&map, &r);
    // Exclusive of an existing key: the key itself stays.
    map.batch_drop(100, false);
    ref_batch_drop(&mut r, 100, false);
    check(&map, &r);
    assert!(map.min_key() == 100);
    // A key that is not in the map.
    map.batch_drop(155, true);
    ref_batch_drop(&mut r, 155, true);
    check(&map, &r);
    assert!(map.min_key() == 160);
    // Below the minimum: a no-op.
    map.batch_drop(3, true);
    check(&map, &r);
    map.batch_drop(0, false);
    check(&map, &r);
    // Everything.
    map.batch_drop(10_000, true);
    ref_batch_drop(&mut r, 10_000, true);
    check(&map, &r);
    assert!(map.is_empty());
    map.destroy_empty();
}

#[test]
fun batch_drop_then_insert_keeps_the_tree_valid() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut round = 0;
    while (round < 6) {
        let mut k = 0;
        while (k < 30) {
            let key = ((round * 100 + k) as u128) + 1;
            insert_bulk(&mut map, &mut r, key, (k as u64), k);
            k = k + 1;
        };
        // Drop about two thirds of what is there.
        let cut = r.keys[r.keys.length() * 2 / 3];
        map.batch_drop(cut, round % 2 == 0);
        ref_batch_drop(&mut r, cut, round % 2 == 0);
        check(&map, &r);
        round = round + 1;
    };
    om::drop(map);
}

// === Randomized operations ===

fun next(seed: &mut u64): u64 {
    let mut s = *seed;
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    *seed = s;
    s
}

fun fuzz(seed: u64, ops: u64, key_space: u64) {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut seed = seed;
    let mut i = 0;
    while (i < ops) {
        let op = next(&mut seed) % 16;
        let key = ((next(&mut seed) % key_space) as u128) + 1;
        if (op < 8) {
            if (!ref_has(&r, key)) insert_both(&mut map, &mut r, key, (next(&mut seed) as u64))
            else {
                *map.borrow_mut(key) = i;
                let idx = ref_lower_bound(&r, key);
                *&mut r.vals[idx] = i;
                check(&map, &r);
            }
        } else if (op < 12) {
            if (!r.keys.is_empty()) {
                let idx = (next(&mut seed) as u64) % r.keys.length();
                let key = r.keys[idx];
                remove_both(&mut map, &mut r, key);
            }
        } else if (op < 14) {
            let removed = map.try_remove(key);
            if (ref_has(&r, key)) {
                assert!(removed.destroy_some() == ref_remove(&mut r, key));
            } else {
                assert!(removed.is_none());
            };
            check(&map, &r);
        } else if (op == 14) {
            let inclusive = next(&mut seed) % 2 == 0;
            map.batch_drop(key, inclusive);
            ref_batch_drop(&mut r, key, inclusive);
            check(&map, &r);
        } else {
            // Drop a random prefix of the present keys, as the matching engine does.
            if (!r.keys.is_empty()) {
                let idx = (next(&mut seed) as u64) % r.keys.length();
                let inclusive = next(&mut seed) % 2 == 0;
                let key = r.keys[idx];
                map.batch_drop(key, inclusive);
                ref_batch_drop(&mut r, key, inclusive);
                check(&map, &r);
            }
        };
        i = i + 1;
    };
    om::drop(map);
}

#[test]
fun fuzz_dense_keys() {
    fuzz(0x9E37_79B9_7F4A_7C15, 220, 48);
}

#[test]
fun fuzz_sparse_keys() {
    fuzz(0xD1B5_4A32_D192_ED03, 220, 1_000_000);
}

#[test]
fun fuzz_insert_heavy() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut seed = 0x2545_F491_4F6C_DD1D;
    let mut i = 0;
    while (i < 80) {
        let key = ((next(&mut seed) % 4096) as u128) + 1;
        if (!ref_has(&r, key)) insert_bulk(&mut map, &mut r, key, i, i);
        i = i + 1;
    };
    check(&map, &r);
    // Then drain it from random positions.
    i = 0;
    while (!r.keys.is_empty()) {
        let idx = (next(&mut seed) as u64) % r.keys.length();
        let key = r.keys[idx];
        remove_bulk(&mut map, &mut r, key, i);
        i = i + 1;
    };
    check(&map, &r);
    map.destroy_empty();
}

// === Parameters ===

#[test]
fun change_params_widens_bounds() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    let mut r = ref_empty();
    let mut k = 1;
    while (k <= 30) {
        insert_both(&mut map, &mut r, k, (k as u64));
        k = k + 1;
    };
    map.change_params(2, 8, 8, 2, 7, 7);
    // Existing nodes stay valid and the map keeps working under the wider bounds.
    k = 31;
    while (k <= 60) {
        map.insert(k, (k as u64));
        ref_insert(&mut r, k, (k as u64));
        k = k + 1;
    };
    assert!(map.map_size() == 60 && map.min_key() == 1);
    k = 1;
    while (k <= 60) {
        assert!(map.remove(k) == (k as u64));
        k = k + 1;
    };
    map.destroy_empty();
}

#[test, expected_failure(abort_code = om::EInvalidMapParameters)]
fun rejects_branch_min_below_two() {
    let ctx = &mut tx_context::dummy();
    let map = om::empty<u64>(1, 4, 4, 2, 3, 3, ctx);
    map.destroy_empty();
}

#[test, expected_failure(abort_code = om::EInvalidMapParameters)]
fun rejects_merge_max_above_max() {
    let ctx = &mut tx_context::dummy();
    let map = om::empty<u64>(2, 5, 4, 2, 3, 3, ctx);
    map.destroy_empty();
}

#[test, expected_failure(abort_code = om::EInvalidMapParameters)]
fun change_params_cannot_narrow() {
    let ctx = &mut tx_context::dummy();
    let mut map = om::empty<u64>(2, 8, 8, 2, 7, 7, ctx);
    let mut k = 1;
    while (k <= 10) {
        map.insert(k, (k as u64));
        k = k + 1;
    };
    map.change_params(2, 4, 4, 2, 3, 3);
    om::drop(map);
}

#[test, expected_failure(abort_code = om::EMapTooSmall)]
fun change_params_needs_more_than_three_entries() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    map.insert(1, 1);
    map.insert(2, 2);
    map.insert(3, 3);
    map.change_params(2, 8, 8, 2, 7, 7);
    om::drop(map);
}

#[test, expected_failure(abort_code = om::EKeyNotExist)]
fun remove_missing_key_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    map.insert(1, 1);
    map.remove(2);
    om::drop(map);
}

#[test, expected_failure(abort_code = om::EKeyNotExist)]
fun borrow_missing_key_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    map.insert(1, 1);
    map.borrow(2);
    om::drop(map);
}

#[test, expected_failure(abort_code = om::EKeyAlreadyExists)]
fun insert_duplicate_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    map.insert(1, 1);
    map.insert(1, 2);
    om::drop(map);
}

#[test, expected_failure(abort_code = om::EDestroyNotEmpty)]
fun destroy_non_empty_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut map = new_map(ctx);
    map.insert(1, 1);
    map.destroy_empty();
}

// === Vector helpers ===

#[test]
fun vector_helpers() {
    let mut v = vector<u64>[1, 2, 3, 4, 5];
    om::reverse(&mut v);
    assert!(v == vector[5, 4, 3, 2, 1]);
    let mut single = vector<u64>[9];
    om::reverse(&mut single);
    assert!(single == vector[9]);
    let mut none = vector<u64>[];
    om::reverse(&mut none);
    assert!(none.is_empty());
    assert!(om::remove_at(&mut v, 0) == 5 && v == vector[4, 3, 2, 1]);
    assert!(om::remove_at(&mut v, 3) == 1 && v == vector[4, 3, 2]);
    assert!(om::remove_at(&mut v, 1) == 3 && v == vector[4, 2]);
}
