// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module ordered_map::ordered_map;

use haneul::dynamic_field;
use ordered_map::enum_option::{Self, Option};

// === Errors and constants (original names from the published interface) ===

const LEAF_FLAG: u64 = 0x8000_0000_0000_0000;
#[error(code = 0x80)]
const EInvalidMapParameters: vector<u8> = b"Invalid map parameters";
#[error(code = 0x81)]
const EKeyNotExist: vector<u8> = b"Key does not exist in the map";
#[error(code = 0x82)]
const EKeyAlreadyExists: vector<u8> = b"Key already exists in the map";
#[error(code = 0x83)]
const EDestroyNotEmpty: vector<u8> = b"Cannot destroy a non-empty map";
#[error(code = 0x84)]
const EMapTooSmall: vector<u8> = b"Map must have more than 3 entries to change parameters";

// === Constants the bodies use that have no named counterpart in the interface ===

const EMPTY_PTRS: vector<u64> = vector[];

// === Types ===

public struct Map<phantom V> has key, store {
    id: UID,
    size: u64,
    counter: u64,
    root: u64,
    first: u64,
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
}

public struct Branch has drop, store { keys: vector<u128>, kids: vector<u64> }

public struct Pair<V> has copy, drop, store { key: u128, val: V }

public struct Leaf<V> has drop, store { keys_vals: vector<Pair<V>>, next: u64 }

// === Functions ===

// The map is a B+ tree whose nodes live in dynamic fields of `Map.id`, keyed by a node pointer.
// Leaf pointers have `LEAF_FLAG` set. Branches hold `keys.length() + 1` kids; leaves hold the
// sorted key/value pairs and link to the next leaf. The `migrate_*` helpers rebalance an underfull
// node with a neighbor and return the new separating key, or 0 when the two nodes were merged.

public fun empty<V: store>(
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
    ctx: &mut TxContext,
): Map<V> {
    check_map_params(
        branch_min,
        branches_merge_max,
        branch_max,
        leaf_min,
        leaves_merge_max,
        leaf_max,
    );
    let mut counter = 0;
    let root = LEAF_FLAG | increase_counter(&mut counter);
    let first = root;
    let mut map = Map {
        id: object::new(ctx),
        counter,
        root,
        first,
        branch_min,
        branches_merge_max,
        branch_max,
        leaf_min,
        leaves_merge_max,
        leaf_max,
        size: 0,
    };
    dynamic_field::add(&mut map.id, root, Leaf<V> { keys_vals: vector[], next: 0 });
    map
}

public fun destroy_empty<V: store>(map: Map<V>) {
    assert!(map.is_empty(), EDestroyNotEmpty);
    let Map {
        mut id,
        size: _,
        counter: _,
        root,
        first: _,
        branch_min: _,
        branches_merge_max: _,
        branch_max: _,
        leaf_min: _,
        leaves_merge_max: _,
        leaf_max: _,
    } = map;
    let Leaf<V> { keys_vals, next: _ } = dynamic_field::remove(&mut id, root);
    keys_vals.destroy_empty();
    id.delete()
}

public fun drop<V: drop + store>(mut map: Map<V>) {
    map.clear();
    map.destroy_empty()
}

public fun is_empty<V>(map: &Map<V>): bool {
    map.size == 0
}

public fun map_size<V>(map: &Map<V>): u64 {
    map.size
}

public fun change_params<V>(
    map: &mut Map<V>,
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
) {
    check_map_params(
        branch_min,
        branches_merge_max,
        branch_max,
        leaf_min,
        leaves_merge_max,
        leaf_max,
    );
    assert!(map.size > 3, EMapTooSmall);
    // The node size bounds may only widen, so that every existing node stays valid.
    assert!(branch_min <= map.branch_min && map.branch_max <= branch_max, EInvalidMapParameters);
    assert!(leaf_min <= map.leaf_min && map.leaf_max <= leaf_max, EInvalidMapParameters);
    map.branch_min = branch_min;
    map.branches_merge_max = branches_merge_max;
    map.branch_max = branch_max;
    map.leaf_min = leaf_min;
    map.leaves_merge_max = leaves_merge_max;
    map.leaf_max = leaf_max
}

public fun min_key<V: store>(map: &Map<V>): u128 {
    dynamic_field::borrow<u64, Leaf<V>>(&map.id, map.first).keys_vals[0].key
}

public fun first_leaf_ptr<V>(map: &Map<V>): u64 {
    map.first
}

public fun get_leaf<V: store>(map: &Map<V>, leaf_ptr: u64): &Leaf<V> {
    dynamic_field::borrow(&map.id, leaf_ptr)
}

public fun get_leaf_mut<V: store>(map: &mut Map<V>, leaf_ptr: u64): &mut Leaf<V> {
    dynamic_field::borrow_mut(&mut map.id, leaf_ptr)
}

public fun size<V>(leaf: &Leaf<V>): u64 {
    leaf.keys_vals.length()
}

public fun elem<V>(leaf: &Leaf<V>, index: u64): (u128, &V) {
    let pair = &leaf.keys_vals[index];
    (pair.key, &pair.val)
}

public fun elem_mut<V>(leaf: &mut Leaf<V>, index: u64): (u128, &mut V) {
    let pair = &mut leaf.keys_vals[index];
    (pair.key, &mut pair.val)
}

public fun next<V>(leaf: &Leaf<V>): u64 {
    leaf.next
}

public fun find_index<V>(leaf: &Leaf<V>, key: u128): u64 {
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    binary_search_p(keys_vals, len, key)
}

public fun find_leaf<V>(map: &Map<V>, key: u128): u64 {
    let mut node_ptr = map.root;
    while (LEAF_FLAG & node_ptr == 0) {
        let branch: &Branch = dynamic_field::borrow(&map.id, node_ptr);
        let keys = &branch.keys;
        let kid_index = binary_search(keys, keys.length(), key);
        node_ptr = branch.kids[kid_index];
    };
    node_ptr
}

public fun has_key<V: store>(map: &Map<V>, key: u128): bool {
    let keys_vals = &dynamic_field::borrow<u64, Leaf<V>>(&map.id, map.find_leaf(key)).keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    index < len && key == keys_vals[index].key
}

public fun borrow<V: store>(map: &Map<V>, key: u128): &V {
    let keys_vals = &dynamic_field::borrow<u64, Leaf<V>>(&map.id, map.find_leaf(key)).keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    assert!(index < len, EKeyNotExist);
    let pair = &keys_vals[index];
    assert!(key == pair.key, EKeyNotExist);
    &pair.val
}

public fun borrow_mut<V: store>(map: &mut Map<V>, key: u128): &mut V {
    let leaf_ptr = map.find_leaf(key);
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, leaf_ptr);
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    assert!(index < len, EKeyNotExist);
    let pair = &mut leaf.keys_vals[index];
    assert!(key == pair.key, EKeyNotExist);
    &mut pair.val
}

public fun insert<V: store>(map: &mut Map<V>, key: u128, val: V) {
    // Walk down to the leaf, remembering (branch pointer, kid index) pairs for the way back up.
    let mut path = EMPTY_PTRS;
    let mut node_ptr = map.root;
    while (LEAF_FLAG & node_ptr == 0) {
        let branch: &Branch = dynamic_field::borrow(&map.id, node_ptr);
        let keys = &branch.keys;
        let kid_index = binary_search(keys, keys.length(), key);
        path.push_back(node_ptr);
        path.push_back(kid_index);
        node_ptr = branch.kids[kid_index];
    };
    let mut counter = map.counter;
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, node_ptr);
    let leaf_len = insert_into_leaf(leaf, key, val);
    map.size = map.size + 1;
    if (leaf_len > map.leaf_max) {
        let (mut new_ptr, mut separating_key, new_leaf) = split_leaf(leaf, &mut counter, leaf_len);
        dynamic_field::add(&mut map.id, new_ptr, new_leaf);
        // Insert the new node into its parent, splitting overfull ancestors up to the root.
        let mut path_len = path.length();
        while (new_ptr != 0) {
            if (path_len > 0) {
                path_len = path_len - 2;
                let kid_index = path.pop_back();
                let branch_ptr = path.pop_back();
                let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
                branch.keys.insert(separating_key, kid_index);
                branch.kids.insert(new_ptr, kid_index + 1);
                let branch_len = branch.kids.length();
                if (branch_len > map.branch_max) {
                    let mut new_branch;
                    (new_ptr, separating_key, new_branch) =
                        split_branch(branch, &mut counter, branch_len);
                    dynamic_field::add(&mut map.id, new_ptr, new_branch)
                } else {
                    break
                }
            } else {
                // The root itself was split: grow the tree by one level.
                let new_root = Branch {
                    keys: vector[separating_key],
                    kids: vector[map.root, new_ptr],
                };
                map.root = increase_counter(&mut counter);
                dynamic_field::add(&mut map.id, map.root, new_root);
                new_ptr = 0;
            }
        };
        map.counter = counter
    }
}

public fun remove<V: copy + drop + store>(map: &mut Map<V>, key: u128): V {
    let root = map.root;
    if (LEAF_FLAG & root == 0) {
        let (val, root_kids) = remove_from_branch(map, root, key);
        // A root branch left with a single kid is replaced by that kid.
        if (root_kids == 1) {
            let mut old_root: Branch = dynamic_field::remove(&mut map.id, root);
            map.root = old_root.kids.pop_back()
        };
        return val
    };
    let (val, _) = remove_from_leaf(map, root, key);
    val
}

public fun try_remove<V: copy + drop + store>(map: &mut Map<V>, key: u128): Option<V> {
    let root = map.root;
    if (LEAF_FLAG & root == 0) {
        let (val, root_kids) = try_remove_from_branch(map, root, key);
        if (root_kids == 1) {
            let mut old_root: Branch = dynamic_field::remove(&mut map.id, root);
            map.root = old_root.kids.pop_back()
        };
        return val
    };
    let (val, _) = try_remove_from_leaf(map, root, key);
    val
}

public fun clear<V: drop + store>(map: &mut Map<V>) {
    // Follow the rightmost path down, dropping every other subtree on the way. The rightmost leaf
    // survives (emptied) as the new root.
    let mut node_ptr = map.root;
    if (LEAF_FLAG & node_ptr == 0) {
        let mut last_index;
        loop {
            let kids = &dynamic_field::remove<u64, Branch>(&mut map.id, node_ptr).kids;
            last_index = kids.length() - 1;
            node_ptr = kids[last_index];
            if (LEAF_FLAG & node_ptr == 0) {
                let mut i = 0;
                while (i < last_index) {
                    drop_branch(map, kids[i]);
                    i = i + 1;
                }
            } else {
                break
            }
        };
        drop_first_leaves(map, last_index);
        map.root = node_ptr
    };
    clear_leaf(map, node_ptr)
}

public fun batch_drop<V: copy + drop + store>(
    map: &mut Map<V>, mut key: u128, inclusive: bool
) {
    if (!inclusive) {
        if (key == 0) {
            return
        };
        key = key - 1;
    };
    batch_drop_from_root(map, key)
}

fun check_map_params(
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
) {
    assert!(2 <= branch_min && branch_min <= branch_max / 2, EInvalidMapParameters);
    assert!(
        2 * branch_min <= branches_merge_max && branches_merge_max <= branch_max,
        EInvalidMapParameters,
    );
    assert!(2 <= leaf_min && leaf_min <= (leaf_max + 1) / 2, EInvalidMapParameters);
    assert!(
        2 * leaf_min - 1 <= leaves_merge_max && leaves_merge_max <= leaf_max,
        EInvalidMapParameters,
    )
}

fun clear_leaf<V: drop + store>(map: &mut Map<V>, leaf_ptr: u64) {
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, leaf_ptr);
    let len = leaf.keys_vals.length();
    leaf.keys_vals = vector[];
    map.size = map.size - len
}

fun split_leaf<V>(
    leaf: &mut Leaf<V>,
    counter: &mut u64,
    len: u64
): (u64, u128, Leaf<V>) {
    let right_len = len >> 1;
    let separating_key = leaf.keys_vals[len - right_len - 1].key;
    let right_keys_vals = cut_right(&mut leaf.keys_vals, right_len);
    let new_leaf_ptr = LEAF_FLAG | increase_counter(counter);
    let next = leaf.next;
    leaf.next = new_leaf_ptr;
    let new_leaf = Leaf { keys_vals: right_keys_vals, next };
    (new_leaf_ptr, separating_key, new_leaf)
}

fun insert_into_leaf<V>(leaf: &mut Leaf<V>, key: u128, val: V): u64 {
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    assert!(index == len || key != keys_vals[index].key, EKeyAlreadyExists);
    leaf.keys_vals.insert(Pair { key, val }, index);
    len + 1
}

fun split_branch(
    branch: &mut Branch,
    counter: &mut u64,
    len: u64
): (u64, u128, Branch) {
    let right_len = len >> 1;
    let right_keys = cut_right(&mut branch.keys, right_len - 1);
    let right_kids = cut_right(&mut branch.kids, right_len);
    // The last key left in the node moves up to the parent as the separator.
    let separating_key = branch.keys.pop_back();
    let new_branch_ptr = increase_counter(counter);
    let new_branch = Branch { keys: right_keys, kids: right_kids };
    (new_branch_ptr, separating_key, new_branch)
}

fun remove_from_branch<V: copy + drop + store>(
    map: &mut Map<V>,
    branch_ptr: u64,
    key: u128,
): (V, u64) {
    let branch: &Branch = dynamic_field::borrow(&map.id, branch_ptr);
    let keys = &branch.keys;
    let mut keys_len = keys.length();
    let kid_index = binary_search(keys, keys_len, key);
    let kids = &branch.kids;
    let kid_ptr = kids[kid_index];
    // An underfull kid is rebalanced with its right neighbor, or with its left one when it is the
    // last kid.
    if (LEAF_FLAG & kid_ptr == 0) {
        if (kid_index < keys_len) {
            let mut separating_key = keys[kid_index];
            let right_index = kid_index + 1;
            let right_ptr = kids[right_index];
            let (val, kid_len) = remove_from_branch(map, kid_ptr, key);
            if (kid_len < map.branch_min) {
                separating_key =
                    migrate_to_left_branch(map, kid_ptr, kid_len, separating_key, right_ptr);
                update_after_migration(
                    map,
                    branch_ptr,
                    &mut keys_len,
                    kid_index,
                    separating_key,
                    right_index,
                )
            };
            return (val, keys_len + 1)
        };
        let left_index = kid_index - 1;
        let left_ptr = kids[left_index];
        let mut separating_key = keys[left_index];
        let (val, kid_len) = remove_from_branch(map, kid_ptr, key);
        if (kid_len < map.branch_min) {
            separating_key =
                migrate_to_right_branch(map, left_ptr, separating_key, kid_ptr, kid_len);
            update_after_migration_last(map, branch_ptr, &mut keys_len, left_index, separating_key)
        };
        return (val, keys_len + 1)
    };
    if (kid_index < keys_len) {
        let right_index = kid_index + 1;
        let right_ptr = kids[right_index];
        let (val, kid_len) = remove_from_leaf(map, kid_ptr, key);
        if (kid_len < map.leaf_min) {
            let separating_key = migrate_to_left_leaf(map, kid_ptr, kid_len, right_ptr);
            update_after_migration(
                map,
                branch_ptr,
                &mut keys_len,
                kid_index,
                separating_key,
                right_index,
            )
        };
        return (val, keys_len + 1)
    };
    let left_index = kid_index - 1;
    let left_ptr = kids[left_index];
    let (val, kid_len) = remove_from_leaf(map, kid_ptr, key);
    if (kid_len < map.leaf_min) {
        let separating_key = migrate_to_right_leaf(map, left_ptr, kid_ptr, kid_len);
        update_after_migration_last(map, branch_ptr, &mut keys_len, left_index, separating_key)
    };
    (val, keys_len + 1)
}

fun try_remove_from_branch<V: copy + drop + store>(
    map: &mut Map<V>,
    branch_ptr: u64,
    key: u128,
): (Option<V>, u64) {
    let branch: &Branch = dynamic_field::borrow(&map.id, branch_ptr);
    let keys = &branch.keys;
    let mut keys_len = keys.length();
    let kid_index = binary_search(keys, keys_len, key);
    let kids = &branch.kids;
    let kid_ptr = kids[kid_index];
    if (LEAF_FLAG & kid_ptr == 0) {
        if (kid_index < keys_len) {
            let mut separating_key = keys[kid_index];
            let right_index = kid_index + 1;
            let right_ptr = kids[right_index];
            let (val, kid_len) = try_remove_from_branch(map, kid_ptr, key);
            if (val.is_none()) {
                return (val, keys_len + 1)
            };
            if (kid_len < map.branch_min) {
                separating_key =
                    migrate_to_left_branch(map, kid_ptr, kid_len, separating_key, right_ptr);
                update_after_migration(
                    map,
                    branch_ptr,
                    &mut keys_len,
                    kid_index,
                    separating_key,
                    right_index,
                )
            };
            return (val, keys_len + 1)
        };
        let left_index = kid_index - 1;
        let left_ptr = kids[left_index];
        let mut separating_key = keys[left_index];
        let (val, kid_len) = try_remove_from_branch(map, kid_ptr, key);
        if (val.is_none()) {
            return (val, keys_len + 1)
        };
        if (kid_len < map.branch_min) {
            separating_key =
                migrate_to_right_branch(map, left_ptr, separating_key, kid_ptr, kid_len);
            update_after_migration_last(map, branch_ptr, &mut keys_len, left_index, separating_key)
        };
        return (val, keys_len + 1)
    };
    if (kid_index < keys_len) {
        let right_index = kid_index + 1;
        let right_ptr = kids[right_index];
        let (val, kid_len) = try_remove_from_leaf(map, kid_ptr, key);
        if (val.is_none()) {
            return (val, keys_len + 1)
        };
        if (kid_len < map.leaf_min) {
            let separating_key = migrate_to_left_leaf(map, kid_ptr, kid_len, right_ptr);
            update_after_migration(
                map,
                branch_ptr,
                &mut keys_len,
                kid_index,
                separating_key,
                right_index,
            )
        };
        return (val, keys_len + 1)
    };
    let left_index = kid_index - 1;
    let left_ptr = kids[left_index];
    let (val, kid_len) = try_remove_from_leaf(map, kid_ptr, key);
    if (val.is_none()) {
        return (val, keys_len + 1)
    };
    if (kid_len < map.leaf_min) {
        let separating_key = migrate_to_right_leaf(map, left_ptr, kid_ptr, kid_len);
        update_after_migration_last(map, branch_ptr, &mut keys_len, left_index, separating_key)
    };
    (val, keys_len + 1)
}

fun migrate_to_left_branch<V>(
    map: &mut Map<V>,
    left: u64,
    left_len: u64,
    separating_key: u128,
    right: u64
): u128 {
    let right_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, right);
    let right_len = right_branch.kids.length();
    let total_len = left_len + right_len;
    if (total_len <= map.branches_merge_max) {
        merge_branches(map, left, separating_key, right);
        return 0
    };
    let moved_len = (total_len + 1) / 2 - left_len;
    let (new_separating_key, moved_keys) = cut_reversed_left1(&mut right_branch.keys, moved_len);
    let moved_kids = cut_reversed_left(&mut right_branch.kids, moved_len);
    let left_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, left);
    left_branch.keys.push_back(separating_key);
    append_reversed_right(&mut left_branch.keys, moved_keys);
    append_reversed_right(&mut left_branch.kids, moved_kids);
    new_separating_key
}

fun migrate_to_right_branch<V>(
    map: &mut Map<V>,
    left: u64,
    separating_key: u128,
    right: u64,
    right_len: u64
): u128 {
    let left_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, left);
    let total_len = left_branch.kids.length() + right_len;
    if (total_len <= map.branches_merge_max) {
        merge_branches(map, left, separating_key, right);
        return 0
    };
    let moved_len = total_len / 2 - right_len;
    let mut moved_keys = cut_right(&mut left_branch.keys, moved_len - 1);
    let new_separating_key = left_branch.keys.pop_back();
    let moved_kids = cut_right(&mut left_branch.kids, moved_len);
    let right_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, right);
    moved_keys.push_back(separating_key);
    append_left(moved_keys, &mut right_branch.keys);
    append_left(moved_kids, &mut right_branch.kids);
    new_separating_key
}

fun merge_branches<V>(map: &mut Map<V>, left: u64, separating_key: u128, right: u64) {
    let Branch { keys: right_keys, kids: right_kids } = dynamic_field::remove(&mut map.id, right);
    let left_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, left);
    left_branch.keys.push_back(separating_key);
    append_right(&mut left_branch.keys, &right_keys);
    append_right(&mut left_branch.kids, &right_kids)
}

fun update_after_migration<V>(
    map: &mut Map<V>,
    branch_ptr: u64,
    branch_len: &mut u64,
    left_index: u64,
    separating_key: u128,
    right_index: u64
) {
    let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
    if (separating_key == 0) {
        let _ = remove_at(&mut branch.keys, left_index);
        let _ = remove_at(&mut branch.kids, right_index);
        *branch_len = *branch_len - 1;
        return
    };
    *&mut branch.keys[left_index] = separating_key
}

fun update_after_migration_last<V>(
    map: &mut Map<V>,
    branch_ptr: u64,
    branch_len: &mut u64,
    left_index: u64,
    separating_key: u128
) {
    let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
    if (separating_key == 0) {
        let _ = branch.keys.pop_back();
        let _ = branch.kids.pop_back();
        *branch_len = *branch_len - 1;
        return
    };
    *&mut branch.keys[left_index] = separating_key
}

fun remove_from_leaf<V: store>(
    map: &mut Map<V>,
    leaf_ptr: u64,
    key: u128
): (V, u64) {
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, leaf_ptr);
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    assert!(index < len, EKeyNotExist);
    let Pair { key: found_key, val } = remove_at(&mut leaf.keys_vals, index);
    assert!(key == found_key, EKeyNotExist);
    map.size = map.size - 1;
    (val, len - 1)
}

fun try_remove_from_leaf<V: store>(
    map: &mut Map<V>,
    leaf_ptr: u64,
    key: u128
): (Option<V>, u64) {
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, leaf_ptr);
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    let index = binary_search_p(keys_vals, len, key);
    if (index == len || key != keys_vals[index].key) {
        return (enum_option::none(), len)
    };
    let Pair { key: _, val } = remove_at(&mut leaf.keys_vals, index);
    map.size = map.size - 1;
    (enum_option::some(val), len - 1)
}

fun migrate_to_left_leaf<V: copy + drop + store>(
    map: &mut Map<V>,
    left: u64,
    left_len: u64,
    right: u64
): u128 {
    let right_leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, right);
    let right_len = right_leaf.keys_vals.length();
    let total_len = left_len + right_len;
    if (total_len <= map.leaves_merge_max) {
        merge_leaves(map, left, right);
        return 0
    };
    let moved_len = total_len / 2 - left_len;
    let moved = cut_reversed_left(&mut right_leaf.keys_vals, moved_len);
    let left_leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, left);
    append_reversed_right(&mut left_leaf.keys_vals, moved);
    last(&left_leaf.keys_vals).key
}

fun migrate_to_right_leaf<V: copy + drop + store>(
    map: &mut Map<V>,
    left: u64,
    right: u64,
    right_len: u64,
): u128 {
    let left_leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, left);
    let total_len = left_leaf.keys_vals.length() + right_len;
    if (total_len <= map.leaves_merge_max) {
        merge_leaves(map, left, right);
        return 0
    };
    let moved_len = total_len / 2 - right_len;
    let moved = cut_right(&mut left_leaf.keys_vals, moved_len);
    let new_separating_key = last(&left_leaf.keys_vals).key;
    let right_leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, right);
    append_left(moved, &mut right_leaf.keys_vals);
    new_separating_key
}

fun merge_leaves<V: copy + drop + store>(map: &mut Map<V>, left: u64, right: u64) {
    let Leaf<V> { keys_vals: right_keys_vals, next } = dynamic_field::remove(&mut map.id, right);
    let left_leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, left);
    append_right(&mut left_leaf.keys_vals, &right_keys_vals);
    left_leaf.next = next
}

// Drops every key <= `key`. Kids that end up entirely below `key` are dropped wholesale; only the
// kid containing `key` is descended into, and it is then rebalanced with its right neighbor.
fun batch_drop_from_root<V: copy + drop + store>(map: &mut Map<V>, key: u128) {
    let mut root = map.root;
    loop {
        if (LEAF_FLAG & root != 0) {
            let _ = batch_drop_from_leaf(map, root, key);
            return
        };
        let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, root);
        let keys = &branch.keys;
        let mut keys_len = keys.length();
        let kid_index = binary_search(keys, keys_len, key);
        // On an exact separator match the kid at `kid_index` holds only keys <= `key` as well.
        let exact_match = kid_index < keys_len && keys[kid_index] == key;
        let mut drop_count;
        if (exact_match) {
            drop_count = kid_index + 1;
        } else {
            drop_count = kid_index;
        };
        let kids = &mut branch.kids;
        let kid_ptr = *&mut kids[kid_index];
        let kids_are_branches = LEAF_FLAG & kid_ptr == 0;
        drop_left(&mut branch.keys, drop_count);
        let mut rev_dropped_kids;
        if (kids_are_branches) {
            rev_dropped_kids = cut_reversed_left(kids, drop_count);
        } else {
            drop_left(kids, drop_count);
            rev_dropped_kids = EMPTY_PTRS;
        };
        keys_len = keys_len - drop_count;
        if (keys_len == 0) {
            // A single kid is left: it becomes the new root.
            drop_kids(map, drop_count, kids_are_branches, rev_dropped_kids);
            root = dynamic_field::remove<u64, Branch>(&mut map.id, root).kids.pop_back();
            map.root = root;
            if (exact_match) {
                return
            }
        } else {
            if (exact_match) {
                drop_kids(map, drop_count, kids_are_branches, rev_dropped_kids);
                return
            };
            let mut separating_key = *&mut branch.keys[0];
            let neighbor = *&mut kids[1];
            drop_kids(map, drop_count, kids_are_branches, rev_dropped_kids);
            if (kids_are_branches) {
                let new_separating_key =
                    batch_drop_from_branch(map, kid_ptr, separating_key, neighbor, key);
                if (new_separating_key != separating_key) {
                    let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, root);
                    if (new_separating_key == 0) {
                        drop_first(&mut branch.keys);
                        drop_second(&mut branch.kids);
                        if (keys_len == 1) {
                            let mut old_root: Branch = dynamic_field::remove(&mut map.id, root);
                            map.root = old_root.kids.pop_back();
                            return
                        };
                        return
                    };
                    *&mut branch.keys[0] = new_separating_key;
                    return
                };
                return
            };
            let kid_len = batch_drop_from_leaf(map, kid_ptr, key);
            if (kid_len < map.leaf_min) {
                separating_key = migrate_to_left_leaf(map, kid_ptr, kid_len, neighbor);
                let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, root);
                if (separating_key == 0) {
                    drop_first(&mut branch.keys);
                    drop_second(&mut branch.kids);
                    if (keys_len == 1) {
                        let mut old_root: Branch = dynamic_field::remove(&mut map.id, root);
                        map.root = old_root.kids.pop_back();
                        return
                    };
                    return
                };
                *&mut branch.keys[0] = separating_key;
                return
            };
            return
        }
    }
}

fun batch_drop_from_branch<V: copy + drop + store>(
    map: &mut Map<V>, branch_ptr: u64, mut branch_separating_key: u128, neighbor: u64, key: u128
): u128 {
    let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
    let keys = &branch.keys;
    let keys_len = keys.length();
    let kid_index = binary_search(keys, keys_len, key);
    let exact_match = kid_index < keys_len && keys[kid_index] == key;
    let drop_count;
    if (exact_match) {
        drop_count = kid_index + 1;
    } else {
        drop_count = kid_index;
    };
    let kids = &mut branch.kids;
    let kid_ptr = *&mut kids[kid_index];
    let kids_are_branches = LEAF_FLAG & kid_ptr == 0;
    drop_left(&mut branch.keys, drop_count);
    let rev_dropped_kids;
    if (kids_are_branches) {
        rev_dropped_kids = cut_reversed_left(kids, drop_count);
    } else {
        drop_left(kids, drop_count);
        rev_dropped_kids = EMPTY_PTRS;
    };
    let branch_len = keys_len - drop_count + 1;
    if (exact_match) {
        if (branch_len < map.branch_min) {
            branch_separating_key = migrate_to_left_branch(
                map,
                branch_ptr,
                branch_len,
                branch_separating_key,
                neighbor,
            );
        };
        drop_kids(map, drop_count, kids_are_branches, rev_dropped_kids);
        return branch_separating_key
    };
    // The kid at `kid_index` is only partially dropped and is now this branch's first kid; keep the
    // first separating key and the second kid to rebalance it afterwards.
    let mut kid_neighbor;
    let mut kid_separating_key;
    if (branch_len <= map.branch_min) {
        (branch_separating_key, kid_separating_key, kid_neighbor) =
            migrate_to_left_branch1(map, branch_ptr, branch_len, branch_separating_key, neighbor);
    } else {
        kid_separating_key = *&mut branch.keys[0];
        kid_neighbor = *&mut kids[1];
    };
    drop_kids(map, drop_count, kids_are_branches, rev_dropped_kids);
    if (kids_are_branches) {
        let new_separating_key =
            batch_drop_from_branch(map, kid_ptr, kid_separating_key, kid_neighbor, key);
        if (new_separating_key != kid_separating_key) {
            let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
            if (new_separating_key == 0) {
                drop_first(&mut branch.keys);
                drop_second(&mut branch.kids);
                return branch_separating_key
            };
            *&mut branch.keys[0] = new_separating_key;
            return branch_separating_key
        };
        return branch_separating_key
    };
    let kid_len = batch_drop_from_leaf(map, kid_ptr, key);
    if (kid_len < map.leaf_min) {
        kid_separating_key = migrate_to_left_leaf(map, kid_ptr, kid_len, kid_neighbor);
        let branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, branch_ptr);
        if (kid_separating_key == 0) {
            drop_first(&mut branch.keys);
            drop_second(&mut branch.kids);
            return branch_separating_key
        };
        *&mut branch.keys[0] = kid_separating_key;
        return branch_separating_key
    };
    branch_separating_key
}

fun drop_kids<V: drop + store>(
    map: &mut Map<V>,
    mut drop_count: u64,
    kids_are_branches: bool,
    mut rev_branch_kids: vector<u64>,
) {
    if (drop_count == 0) {
        return
    };
    if (kids_are_branches) {
        while (drop_count > 0) {
            drop_count = drop_count - 1;
            drop_branch(map, rev_branch_kids.pop_back())
        }
    } else {
        drop_first_leaves(map, drop_count)
    }
}

// Same as `migrate_to_left_branch`, but also returns the left branch's first key and second kid
// after the migration.
fun migrate_to_left_branch1<V>(
    map: &mut Map<V>, left: u64, left_len: u64, separating_key: u128, right: u64
): (u128, u128, u64) {
    let right_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, right);
    let right_len = right_branch.kids.length();
    let total_len = left_len + right_len;
    if (total_len <= map.branches_merge_max) {
        let Branch { keys: right_keys, kids: right_kids } =
            dynamic_field::remove(&mut map.id, right);
        let left_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, left);
        let left_keys = &mut left_branch.keys;
        let left_kids = &mut left_branch.kids;
        left_keys.push_back(separating_key);
        append_right(left_keys, &right_keys);
        append_right(left_kids, &right_kids);
        return (0, *&mut left_keys[0], *&mut left_kids[1])
    };
    let moved_len = (total_len + 1) / 2 - left_len;
    let (new_separating_key, moved_keys) = cut_reversed_left1(&mut right_branch.keys, moved_len);
    let moved_kids = cut_reversed_left(&mut right_branch.kids, moved_len);
    let left_branch: &mut Branch = dynamic_field::borrow_mut(&mut map.id, left);
    let left_keys = &mut left_branch.keys;
    let left_kids = &mut left_branch.kids;
    left_keys.push_back(separating_key);
    append_reversed_right(left_keys, moved_keys);
    append_reversed_right(left_kids, moved_kids);
    (new_separating_key, *&mut left_keys[0], *&mut left_kids[1])
}

fun batch_drop_from_leaf<V: copy + drop + store>(map: &mut Map<V>, leaf_ptr: u64, key: u128): u64 {
    let leaf: &mut Leaf<V> = dynamic_field::borrow_mut(&mut map.id, leaf_ptr);
    let keys_vals = &leaf.keys_vals;
    let len = keys_vals.length();
    let drop_count = binary_search_rightmost(keys_vals, len, key);
    drop_left(&mut leaf.keys_vals, drop_count);
    map.size = map.size - drop_count;
    len - drop_count
}

fun drop_branch<V: drop + store>(map: &mut Map<V>, branch_ptr: u64) {
    let kids = &dynamic_field::remove<u64, Branch>(&mut map.id, branch_ptr).kids;
    let kids_len = kids.length();
    let first_kid = kids[0];
    if (LEAF_FLAG & first_kid == 0) {
        drop_branch(map, first_kid);
        let mut i = 1;
        while (i < kids_len) {
            drop_branch(map, kids[i]);
            i = i + 1;
        };
        return
    };
    // Leaves are dropped from the front of the leaf list.
    drop_first_leaves(map, kids_len)
}

fun drop_first_leaves<V: drop + store>(map: &mut Map<V>, mut count: u64) {
    let mut dropped_size = 0;
    let mut leaf_ptr = map.first;
    while (count > 0) {
        let leaf: Leaf<V> = dynamic_field::remove(&mut map.id, leaf_ptr);
        dropped_size = dropped_size + leaf.keys_vals.length();
        leaf_ptr = leaf.next;
        count = count - 1;
    };
    map.size = map.size - dropped_size;
    map.first = leaf_ptr
}

fun increase_counter(counter: &mut u64): u64 {
    *counter = *counter + 1;
    *counter
}

public fun reverse<V>(vec: &mut vector<V>) {
    let mut last = vec.length();
    if (last <= 1) {
        return
    };
    let mut i = last / 2;
    last = last - 1;
    while (i > 0) {
        i = i - 1;
        vec.swap(i, last - i)
    }
}

public fun remove_at<V>(vec: &mut vector<V>, index: u64): V {
    // Bubbles the element to the end, keeping the order of the others.
    let mut i = vec.length() - 1;
    while (i != index) {
        vec.swap(index, i);
        i = i - 1;
    };
    vec.pop_back()
}

fun last<V>(vec: &vector<V>): &V {
    &vec[vec.length() - 1]
}

fun binary_search(vec: &vector<u128>, mut r: u64, key: u128): u64 {
    let mut l = 0;
    while (l < r) {
        let mid = l + r >> 1;
        if (vec[mid] < key) {
            l = mid + 1;
        } else {
            r = mid;
        }
    };
    l
}

fun binary_search_p<V>(vec: &vector<Pair<V>>, mut r: u64, key: u128): u64 {
    let mut l = 0;
    while (l < r) {
        let mid = l + r >> 1;
        if (vec[mid].key < key) {
            l = mid + 1;
        } else {
            r = mid;
        }
    };
    l
}

fun binary_search_rightmost<V>(vec: &vector<Pair<V>>, mut r: u64, key: u128): u64 {
    let mut l = 0;
    while (l < r) {
        let mid = l + r >> 1;
        if (vec[mid].key > key) {
            r = mid;
        } else {
            l = mid + 1;
        }
    };
    r
}

fun copy_slice<V: copy>(vec: &vector<V>, mut from: u64, to: u64): vector<V> {
    let mut slice = vector[];
    while (from < to) {
        slice.push_back(vec[from]);
        from = from + 1;
    };
    slice
}

fun cut_reversed_right<V>(vec: &mut vector<V>, mut count: u64): vector<V> {
    let mut cut = vector[];
    while (count > 0) {
        cut.push_back(vec.pop_back());
        count = count - 1;
    };
    cut
}

fun cut_right<V>(vec: &mut vector<V>, count: u64): vector<V> {
    let mut cut = cut_reversed_right(vec, count);
    reverse(&mut cut);
    cut
}

fun append_reversed_right<V>(left: &mut vector<V>, mut reversed_right: vector<V>) {
    while (reversed_right.length() > 0) {
        left.push_back(reversed_right.pop_back())
    };
    reversed_right.destroy_empty()
}

fun append_right<V: copy>(left: &mut vector<V>, right: &vector<V>) {
    let mut i = 0;
    while (i < right.length()) {
        left.push_back(right[i]);
        i = i + 1;
    }
}

fun cut_reversed_left<V: copy + drop>(vec: &mut vector<V>, count: u64): vector<V> {
    let mut cut = vector[];
    let mut i = count;
    while (i > 0) {
        i = i - 1;
        cut.push_back(*&mut vec[i])
    };
    drop_left(vec, count);
    cut
}

fun cut_reversed_left1<V: copy + drop>(vec: &mut vector<V>, count: u64): (V, vector<V>) {
    let mut cut = vector[];
    let mut i = count - 1;
    let last_cut = *&mut vec[i];
    while (i > 0) {
        i = i - 1;
        cut.push_back(*&mut vec[i])
    };
    drop_left(vec, count);
    (last_cut, cut)
}

fun append_left<V>(left: vector<V>, right: &mut vector<V>) {
    reverse(right);
    append_reversed_right(right, left);
    reverse(right)
}

fun drop_right<V: drop>(vec: &mut vector<V>, mut count: u64) {
    while (count > 0) {
        let _ = vec.pop_back();
        count = count - 1;
    }
}

fun drop_left<V: copy + drop>(vec: &mut vector<V>, count: u64) {
    let len = vec.length();
    // Copying the kept tail is cheaper than shifting when more than half is dropped.
    if (2 * count > len) {
        *vec = copy_slice(vec, count, len);
        return
    };
    let mut i = count;
    while (i < len) {
        vec.swap(i - count, i);
        i = i + 1;
    };
    drop_right(vec, count)
}

fun drop_first<V: drop>(vec: &mut vector<V>) {
    let mut i = vec.length();
    while (i > 1) {
        i = i - 1;
        vec.swap(0, i)
    };
    let _ = vec.pop_back();
}

fun drop_second<V: drop>(vec: &mut vector<V>) {
    let mut i = vec.length();
    while (i != 2) {
        i = i - 1;
        vec.swap(1, i)
    };
    let _ = vec.pop_back();
}
