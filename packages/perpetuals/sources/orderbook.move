// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::orderbook;

use haneul::dynamic_object_field;
use ifixed::ifixed;
use ordered_map::ordered_map::{Self, Map};
use perpetuals::account::IntegratorInfo;
use perpetuals::keys;

// === Errors and constants ===

const EInvalidUserForOrder: u64 = 3000;
const EInvalidMapParams: u64 = 3001;

// Order ids are `price << 64 | counter`. Bids store the bitwise complement of the price so that
// both maps iterate from the best price; this also sets the top bit, so asks are exactly the ids
// below 2^127.

// === Types ===

public struct Order has copy, drop, store {
    account_id: u64,
    size: u64,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
    integrator_info: Option<IntegratorInfo>,
    client_order_id: Option<u64>,
}

public struct Orderbook has key, store {
    id: UID,
    counter: u64,
    best_ask_price: Option<u64>,
    best_bid_price: Option<u64>,
}

// === Functions ===

public fun as_parts(order: &Order): (
    u64,
    u64,
    bool,
    Option<u64>,
    Option<u64>,
    Option<IntegratorInfo>,
) {
    (
        order.account_id,
        order.size,
        order.reduce_only,
        order.expiration_timestamp_ms,
        order.client_order_id,
        order.integrator_info,
    )
}

public(package) fun create_orderbook(
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
    ctx: &mut TxContext,
): Orderbook {
    assert!(branch_max <= 200, EInvalidMapParams);
    assert!(leaf_max <= 200, EInvalidMapParams);
    let mut orderbook = Orderbook {
        id: object::new(ctx),
        counter: 0,
        best_ask_price: option::none(),
        best_bid_price: option::none(),
    };
    dynamic_object_field::add(
        &mut orderbook.id,
        keys::asks_map(),
        ordered_map::empty<Order>(
            branch_min,
            branches_merge_max,
            branch_max,
            leaf_min,
            leaves_merge_max,
            leaf_max,
            ctx,
        ),
    );
    dynamic_object_field::add(
        &mut orderbook.id,
        keys::bids_map(),
        ordered_map::empty<Order>(
            branch_min,
            branches_merge_max,
            branch_max,
            leaf_min,
            leaves_merge_max,
            leaf_max,
            ctx,
        ),
    );
    orderbook
}

/// Mid price of the best ask and best bid, if both sides are non-empty.
public fun book_price(book: &Orderbook): Option<u64> {
    if (book.best_ask_price.is_none() || book.best_bid_price.is_none()) {
        option::none()
    } else {
        let best_ask_price = *book.best_ask_price.borrow();
        let best_bid_price = *book.best_bid_price.borrow();
        option::some((best_ask_price + best_bid_price) / 2)
    }
}

public fun best_price(book: &Orderbook, side: bool): Option<u64> {
    if (side) {
        if (book.best_ask_price.is_none()) {
            return option::none()
        };
        return book.best_ask_price
    };
    if (book.best_bid_price.is_none()) {
        return option::none()
    };
    book.best_bid_price
}

public fun book_price_or_index(orderbook: &Orderbook, index_price: u256): u256 {
    let book_price = orderbook.book_price();
    if (book_price.is_none()) {
        return index_price
    };
    ifixed::from_balance(book_price.destroy_some(), 1_000_000_000)
}

public fun order_size(book: &Orderbook, order_id: u128): u64 {
    let order = if ((order_id < 0x8000_0000_0000_0000_0000_0000_0000_0000) == true) {
        book.asks().borrow(order_id)
    } else {
        book.bids().borrow(order_id)
    };
    order.size
}

public fun get_order(book: &Orderbook, order_id: u128): Option<Order> {
    let map;
    if (order_id < 0x8000_0000_0000_0000_0000_0000_0000_0000) {
        map = book.asks();
    } else {
        map = book.bids();
    };
    if (!map.has_key(order_id)) {
        return option::none()
    };
    option::some(*map.borrow(order_id))
}

public(package) fun asks(self: &Orderbook): &Map<Order> {
    dynamic_object_field::borrow(&self.id, keys::asks_map())
}

public(package) fun borrow_mut_asks(self: &mut Orderbook): &mut Map<Order> {
    dynamic_object_field::borrow_mut(&mut self.id, keys::asks_map())
}

public(package) fun bids(self: &Orderbook): &Map<Order> {
    dynamic_object_field::borrow(&self.id, keys::bids_map())
}

public(package) fun borrow_mut_bids(self: &mut Orderbook): &mut Map<Order> {
    dynamic_object_field::borrow_mut(&mut self.id, keys::bids_map())
}

public(package) fun order_snapshot(
    order: &Order
): (u64, Option<u64>, u64, bool, Option<u64>, Option<IntegratorInfo>) {
    (
        order.account_id,
        order.client_order_id,
        order.size,
        order.reduce_only,
        order.expiration_timestamp_ms,
        order.integrator_info,
    )
}

/// Returns up to `limit` (capped at 50) orders of one side, starting at `price_from` and stopping
/// before `price_to`, in book order.
public fun inspect_orders(
    orderbook: &Orderbook,
    side: bool,
    price_from: u64,
    price_to: u64,
    mut limit: u64,
): (
    vector<u128>,
    vector<Order>,
) {
    if (limit == 0) {
        return (vector[], vector[])
    };
    if (limit > 50) {
        limit = 50;
    };

    let map;
    let from_key;
    let to_key_price;
    if (side) {
        map = orderbook.asks();
        from_key = (price_from as u128) << 64 | 0;
        to_key_price = price_to;
    } else {
        map = orderbook.bids();
        from_key = ((price_from ^ 0xffff_ffff_ffff_ffff) as u128) << 64 | 0;
        to_key_price = price_to ^ 0xffff_ffff_ffff_ffff;
    };

    let (mut order_ids, mut orders) = (vector[], vector[]);
    let mut leaf_idx = map.find_leaf(from_key);
    let mut leaf = map.get_leaf(leaf_idx);
    let mut idx = leaf.find_index(from_key);
    loop {
        let leaf_size = leaf.size();
        while (idx < leaf_size) {
            let (order_id, order) = leaf.elem(idx);
            if (((order_id >> 64) as u64) >= to_key_price) {
                return (order_ids, orders)
            };
            order_ids.push_back(order_id);
            orders.push_back(*order);
            if (order_ids.length() == limit) {
                return (order_ids, orders)
            };
            idx = idx + 1;
        };
        leaf_idx = leaf.next();
        if (leaf_idx == 0) {
            return (order_ids, orders)
        };
        leaf = map.get_leaf(leaf_idx);
        idx = 0;
    }
}

public(package) fun cancel_limit_order(
    orderbook: &mut Orderbook,
    account_id: u64,
    order_id: u128
): (u64, Option<u64>) {
    let is_ask = order_id < 0x8000_0000_0000_0000_0000_0000_0000_0000;
    let price = if (is_ask) {
        ((order_id >> 64) as u64)
    } else {
        ((order_id >> 64) as u64) ^ 0xffff_ffff_ffff_ffff
    };
    let best_price;
    let map;
    if (is_ask) {
        best_price = &mut orderbook.best_ask_price;
        map = dynamic_object_field::borrow_mut<_, Map<Order>>(&mut orderbook.id, keys::asks_map());
    } else {
        best_price = &mut orderbook.best_bid_price;
        map = dynamic_object_field::borrow_mut<_, Map<Order>>(&mut orderbook.id, keys::bids_map());
    };
    let was_best_price = best_price.is_some() && *best_price.borrow() == price;

    let order = map.remove(order_id);
    if (account_id != order.account_id) {
        abort EInvalidUserForOrder
    };
    if (was_best_price) {
        if (map.is_empty()) {
            *best_price = option::none()
        } else {
            let best_order_id = map.min_key();
            *best_price = option::some(if (is_ask) {
                ((best_order_id >> 64) as u64)
            } else {
                ((best_order_id >> 64) as u64) ^ 0xffff_ffff_ffff_ffff
            })
        }
    };
    (order.size, order.client_order_id)
}

public(package) fun try_cancel_limit_order(
    orderbook: &mut Orderbook,
    account_id: u64,
    order_id: u128
): (bool, u64, Option<u64>) {
    let is_ask = order_id < 0x8000_0000_0000_0000_0000_0000_0000_0000;
    let price = if (is_ask) {
        ((order_id >> 64) as u64)
    } else {
        ((order_id >> 64) as u64) ^ 0xffff_ffff_ffff_ffff
    };
    let (best_price, map) = if (is_ask) {
        (
            &mut orderbook.best_ask_price,
            dynamic_object_field::borrow_mut<_, Map<Order>>(&mut orderbook.id, keys::asks_map()),
        )
    } else {
        (
            &mut orderbook.best_bid_price,
            dynamic_object_field::borrow_mut<_, Map<Order>>(&mut orderbook.id, keys::bids_map()),
        )
    };
    let was_best_price = best_price.is_some() && *best_price.borrow() == price;

    let order = map.try_remove(order_id);
    if (order.is_none()) {
        return (false, 0, option::none())
    };
    let order = order.destroy_some();
    assert!(account_id == order.account_id, EInvalidUserForOrder);
    if (was_best_price) {
        if (map.is_empty()) {
            *best_price = option::none()
        } else {
            let best_order_id = map.min_key();
            *best_price = option::some(if (is_ask) {
                ((best_order_id >> 64) as u64)
            } else {
                ((best_order_id >> 64) as u64) ^ 0xffff_ffff_ffff_ffff
            })
        }
    };
    (true, order.size, order.client_order_id)
}

/// Cancels an order that expired, or a reduce-only order that would no longer reduce the
/// account's position. Returns `(canceled, expired, size, client_order_id)`.
public(package) fun try_cancel_stale_limit_order(
    orderbook: &mut Orderbook,
    account_id: u64,
    order_id: u128,
    timestamp_ms: u64,
    account_base: u256,
): (bool, bool, u64, Option<u64>) {
    let order = orderbook.get_order(order_id);
    if (order.is_none()) {
        return (false, false, 0, option::none())
    };
    let order = order.destroy_some();
    assert!(account_id == order.account_id, EInvalidUserForOrder);

    let is_expired = order.expiration_timestamp_ms.is_some()
        && *order.expiration_timestamp_ms.borrow() <= timestamp_ms;
    let is_ask = order_id < 0x8000_0000_0000_0000_0000_0000_0000_0000;
    // An ask reduces a long position, a bid reduces a short one.
    let reduces_position = account_base != 0
        && ((is_ask && !ifixed::is_neg(account_base)) || (!is_ask && ifixed::is_neg(account_base)));
    let is_invalid_reduce_only = order.reduce_only && !reduces_position;
    if (!is_expired && !is_invalid_reduce_only) {
        return (false, false, 0, option::none())
    };

    let (_, size, client_order_id) = orderbook.try_cancel_limit_order(account_id, order_id);
    (true, is_expired, size, client_order_id)
}

public(package) fun post_order(
    orderbook: &mut Orderbook,
    account_id: u64,
    side: bool,
    size: u64,
    price: u64,
    client_order_id: Option<u64>,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
    integrator_info: Option<IntegratorInfo>,
): u128 {
    let counter = increase_counter(&mut orderbook.counter);
    let is_ask = side;
    let order_id;
    if (is_ask) {
        order_id = (price as u128) << 64 | (counter as u128);
    } else {
        order_id = ((price ^ 0xffff_ffff_ffff_ffff) as u128) << 64 | (counter as u128);
    };

    if (is_ask) {
        if (orderbook.best_ask_price.is_none() || price < *orderbook.best_ask_price.borrow()) {
            orderbook.best_ask_price = option::some(price)
        }
    } else {
        if (orderbook.best_bid_price.is_none() || price > *orderbook.best_bid_price.borrow()) {
            orderbook.best_bid_price = option::some(price)
        }
    };

    let order = Order {
        account_id,
        size,
        reduce_only,
        expiration_timestamp_ms,
        integrator_info,
        client_order_id,
    };
    if (is_ask) {
        orderbook.borrow_mut_asks().insert(order_id, order)
    } else {
        orderbook.borrow_mut_bids().insert(order_id, order)
    };
    order_id
}

public(package) fun reduce_order_size(
    order: &mut Order,
    size_to_reduce: u64,
) {
    order.size = order.size - size_to_reduce
}

public(package) fun set_best_price(
    orderbook: &mut Orderbook,
    side: bool,
    best_price: Option<u64>,
) {
    if (side) {
        orderbook.best_ask_price = best_price
    } else {
        orderbook.best_bid_price = best_price
    }
}

fun increase_counter(counter: &mut u64): u64 {
    *counter = *counter + 1;
    *counter
}
