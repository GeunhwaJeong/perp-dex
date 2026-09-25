// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for the order book on its own: order id encoding, price-time priority, best price
/// maintenance across posts and cancels, stale order cancelation and book inspection.
#[test_only]
module perpetuals::orderbook_tests;

use haneul::tx_context;
use ifixed::ifixed;
use ordered_map::ordered_map as om;
use perpetuals::account;
use perpetuals::orderbook::{Self as ob, Orderbook};

const ASK: bool = true;
const BID: bool = false;
const MAX_U64: u64 = 0xffff_ffff_ffff_ffff;
const TOP_BIT: u128 = 1 << 127;

fun new_book(): Orderbook {
    let ctx = &mut tx_context::dummy();
    // Tiny nodes so that a dozen orders already split the tree.
    ob::create_orderbook(2, 4, 4, 2, 3, 3, ctx)
}

fun done(book: Orderbook) {
    transfer::public_transfer(book, @0x0)
}

fun post(book: &mut Orderbook, account_id: u64, side: bool, size: u64, price: u64): u128 {
    book.post_order(account_id, side, size, price, option::none(), false, option::none(), option::none())
}

fun price_of(order_id: u128): u64 {
    let raw = ((order_id >> 64) as u64);
    if (order_id < TOP_BIT) raw else raw ^ MAX_U64
}

// === Order ids ===

#[test]
fun order_ids_encode_price_side_and_time_priority() {
    let mut book = new_book();
    let ask = post(&mut book, 1, ASK, 10, 100);
    let bid = post(&mut book, 2, BID, 10, 90);
    // The price sits in the upper 64 bits and the counter in the lower 64.
    assert!(ask == (100u128 << 64) | 1);
    assert!(bid == (((90 ^ MAX_U64) as u128) << 64) | 2);
    // Asks keep the top bit clear, bids set it.
    assert!(ask < TOP_BIT && bid >= TOP_BIT);
    assert!(price_of(ask) == 100 && price_of(bid) == 90);
    // The counter is shared by both sides and only ever grows.
    let later_ask = post(&mut book, 1, ASK, 10, 100);
    assert!(later_ask == (100u128 << 64) | 3 && later_ask > ask);
    done(book);
}

#[test]
fun both_sides_iterate_from_the_best_price() {
    let mut book = new_book();
    let ask_110 = post(&mut book, 1, ASK, 1, 110);
    let ask_90 = post(&mut book, 1, ASK, 1, 90);
    let ask_100 = post(&mut book, 1, ASK, 1, 100);
    let bid_50 = post(&mut book, 2, BID, 1, 50);
    let bid_70 = post(&mut book, 2, BID, 1, 70);
    let bid_60 = post(&mut book, 2, BID, 1, 60);
    // Lower ids come first: cheapest ask, highest bid.
    assert!(ask_90 < ask_100 && ask_100 < ask_110);
    assert!(bid_70 < bid_60 && bid_60 < bid_50);
    assert!(book.asks().min_key() == ask_90);
    assert!(book.bids().min_key() == bid_70);
    assert!(book.asks().map_size() == 3 && book.bids().map_size() == 3);
    done(book);
}

// === Best prices ===

#[test]
fun best_prices_follow_posts() {
    let mut book = new_book();
    assert!(book.best_price(ASK).is_none() && book.best_price(BID).is_none());
    assert!(book.book_price().is_none());
    assert!(book.book_price_or_index(12345) == 12345);
    post(&mut book, 1, ASK, 1, 100);
    assert!(book.best_price(ASK) == option::some(100));
    post(&mut book, 1, ASK, 1, 110);
    assert!(book.best_price(ASK) == option::some(100));
    post(&mut book, 1, ASK, 1, 90);
    assert!(book.best_price(ASK) == option::some(90));
    // One side alone gives no book price.
    assert!(book.book_price().is_none());
    post(&mut book, 2, BID, 1, 60);
    post(&mut book, 2, BID, 1, 50);
    assert!(book.best_price(BID) == option::some(60));
    post(&mut book, 2, BID, 1, 70);
    assert!(book.best_price(BID) == option::some(70));
    // Mid price, in 9-decimal price units and as an 18-decimal value.
    assert!(book.book_price() == option::some(80));
    assert!(book.book_price_or_index(12345) == 80 * 1_000_000_000);
    done(book);
}

#[test]
fun best_prices_follow_cancels() {
    let mut book = new_book();
    let ask_90 = post(&mut book, 1, ASK, 5, 90);
    let ask_100 = post(&mut book, 1, ASK, 6, 100);
    let ask_110 = post(&mut book, 1, ASK, 7, 110);
    // Canceling a non-best order leaves the best price alone.
    let (size, client_id) = book.cancel_limit_order(1, ask_100);
    assert!(size == 6 && client_id.is_none());
    assert!(book.best_price(ASK) == option::some(90));
    // Canceling the best order moves it to the next level.
    let (size, _) = book.cancel_limit_order(1, ask_90);
    assert!(size == 5 && book.best_price(ASK) == option::some(110));
    // Canceling the last order empties the side.
    book.cancel_limit_order(1, ask_110);
    assert!(book.best_price(ASK).is_none() && book.asks().is_empty());
    // The same on the bid side, where the best is the highest price.
    let bid_60 = post(&mut book, 2, BID, 1, 60);
    let bid_70 = post(&mut book, 2, BID, 1, 70);
    book.cancel_limit_order(2, bid_70);
    assert!(book.best_price(BID) == option::some(60));
    book.cancel_limit_order(2, bid_60);
    assert!(book.best_price(BID).is_none());
    done(book);
}

#[test]
fun set_best_price_overrides() {
    let mut book = new_book();
    post(&mut book, 1, ASK, 1, 100);
    book.set_best_price(ASK, option::some(95));
    assert!(book.best_price(ASK) == option::some(95));
    book.set_best_price(BID, option::some(80));
    assert!(book.best_price(BID) == option::some(80));
    book.set_best_price(ASK, option::none());
    assert!(book.best_price(ASK).is_none());
    done(book);
}

// === Cancels ===

#[test]
fun cancel_returns_size_and_client_order_id() {
    let mut book = new_book();
    let id = book.post_order(7, BID, 42, 100, option::some(999), true, option::some(5_000), option::none());
    let order = book.get_order(id).destroy_some();
    let (account_id, size, reduce_only, expiration, client_order_id, integrator) = order.as_parts();
    assert!(account_id == 7 && size == 42 && reduce_only);
    assert!(expiration == option::some(5_000) && client_order_id == option::some(999));
    assert!(integrator.is_none());
    assert!(book.order_size(id) == 42);
    let (size, client_order_id) = book.cancel_limit_order(7, id);
    assert!(size == 42 && client_order_id == option::some(999));
    assert!(book.get_order(id).is_none());
    done(book);
}

#[test, expected_failure(abort_code = 3000, location = perpetuals::orderbook)]
fun cancel_rejects_another_accounts_order() {
    let mut book = new_book();
    let id = post(&mut book, 1, ASK, 1, 100);
    book.cancel_limit_order(2, id);
    done(book);
}

#[test, expected_failure(abort_code = om::EKeyNotExist)]
fun cancel_rejects_unknown_order() {
    let mut book = new_book();
    post(&mut book, 1, ASK, 1, 100);
    book.cancel_limit_order(1, (100u128 << 64) | 99);
    done(book);
}

#[test]
fun try_cancel_reports_unknown_orders() {
    let mut book = new_book();
    let id = post(&mut book, 1, ASK, 3, 100);
    let (canceled, size, _) = book.try_cancel_limit_order(1, (100u128 << 64) | 99);
    assert!(!canceled && size == 0);
    assert!(book.asks().map_size() == 1 && book.best_price(ASK) == option::some(100));
    let (canceled, size, _) = book.try_cancel_limit_order(1, id);
    assert!(canceled && size == 3);
    assert!(book.asks().is_empty() && book.best_price(ASK).is_none());
    let (canceled, _, _) = book.try_cancel_limit_order(1, id);
    assert!(!canceled);
    done(book);
}

#[test, expected_failure(abort_code = 3000, location = perpetuals::orderbook)]
fun try_cancel_rejects_another_accounts_order() {
    let mut book = new_book();
    let id = post(&mut book, 1, ASK, 1, 100);
    book.try_cancel_limit_order(2, id);
    done(book);
}

#[test]
fun stale_cancel_handles_expiry_and_reduce_only() {
    let mut book = new_book();
    let long = 5 * 1_000_000_000_000_000_000;
    let short = ifixed::neg(long);
    let expiring = book.post_order(1, ASK, 1, 100, option::none(), false, option::some(1_000), option::none());
    let reduce_only_ask = book.post_order(1, ASK, 1, 101, option::none(), true, option::none(), option::none());
    let reduce_only_bid = book.post_order(1, BID, 1, 90, option::none(), true, option::none(), option::none());
    let plain = post(&mut book, 1, ASK, 1, 102);

    // Not yet expired, and a reduce-only ask still reduces a long: nothing is canceled.
    let (canceled, _, _, _) = book.try_cancel_stale_limit_order(1, expiring, 999, long);
    assert!(!canceled);
    let (canceled, _, _, _) = book.try_cancel_stale_limit_order(1, reduce_only_ask, 0, long);
    assert!(!canceled);
    let (canceled, _, _, _) = book.try_cancel_stale_limit_order(1, reduce_only_bid, 0, short);
    assert!(!canceled);
    let (canceled, _, _, _) = book.try_cancel_stale_limit_order(1, plain, 0, 0);
    assert!(!canceled);
    assert!(book.asks().map_size() == 3);

    // Expiry is inclusive of the timestamp.
    let (canceled, expired, size, _) = book.try_cancel_stale_limit_order(1, expiring, 1_000, long);
    assert!(canceled && expired && size == 1);
    // A reduce-only ask no longer reduces a flat or short position.
    let (canceled, expired, _, _) = book.try_cancel_stale_limit_order(1, reduce_only_ask, 0, 0);
    assert!(canceled && !expired);
    // A reduce-only bid no longer reduces a long position.
    let (canceled, expired, _, _) = book.try_cancel_stale_limit_order(1, reduce_only_bid, 0, long);
    assert!(canceled && !expired);
    // An already canceled order is reported as absent.
    let (canceled, _, _, _) = book.try_cancel_stale_limit_order(1, expiring, 5_000, long);
    assert!(!canceled);
    assert!(book.asks().map_size() == 1 && book.best_price(ASK) == option::some(102));
    done(book);
}

#[test, expected_failure(abort_code = 3000, location = perpetuals::orderbook)]
fun stale_cancel_rejects_another_accounts_order() {
    let mut book = new_book();
    let id = post(&mut book, 1, ASK, 1, 100);
    book.try_cancel_stale_limit_order(2, id, 0, 0);
    done(book);
}

// === Order mutation ===

#[test]
fun orders_can_be_reduced_in_place() {
    let mut book = new_book();
    let id = post(&mut book, 1, ASK, 10, 100);
    book.borrow_mut_asks().borrow_mut(id).reduce_order_size(4);
    assert!(book.order_size(id) == 6);
    let bid = post(&mut book, 2, BID, 10, 90);
    book.borrow_mut_bids().borrow_mut(bid).reduce_order_size(10);
    assert!(book.order_size(bid) == 0);
    done(book);
}

#[test]
fun integrator_info_is_stored_with_the_order() {
    let mut book = new_book();
    let info = account::create_integrator_info(3, 1_000_000);
    let id = book.post_order(1, ASK, 1, 100, option::none(), false, option::none(), info);
    let (_, _, _, _, _, stored) = book.get_order(id).destroy_some().as_parts();
    let stored = stored.destroy_some();
    assert!(stored.integrator_id() == 3 && stored.integrator_fee_b9() == 1_000_000);
    // One billionth units: 0.1% is 1_000_000 b9.
    assert!(stored.integrator_fee() == 1_000_000_000_000_000);
    done(book);
}

// === Inspection ===

fun ladder(book: &mut Orderbook) {
    // Asks at 100..119 and bids at 80..99, two orders per level.
    let mut i = 0;
    while (i < 20) {
        post(book, 1, ASK, i + 1, 100 + i);
        post(book, 1, ASK, i + 1, 100 + i);
        post(book, 2, BID, i + 1, 80 + i);
        post(book, 2, BID, i + 1, 80 + i);
        i = i + 1;
    }
}

#[test]
fun inspect_orders_walks_a_price_range_in_book_order() {
    let mut book = new_book();
    ladder(&mut book);
    assert!(book.asks().map_size() == 40 && book.bids().map_size() == 40);
    // Asks from 105 up to (excluding) 108: three levels of two orders.
    let (ids, orders) = book.inspect_orders(ASK, 105, 108, 100);
    assert!(ids.length() == 6 && orders.length() == 6);
    let mut i = 0;
    while (i < 6) {
        assert!(price_of(ids[i]) == 105 + i / 2);
        let (_, size, _, _, _, _) = orders[i].as_parts();
        assert!(size == 6 + i / 2);
        if (i > 0) assert!(ids[i] > ids[i - 1]);
        i = i + 1;
    };
    // Bids walk downward: from 95 down to (excluding) 92.
    let (ids, _) = book.inspect_orders(BID, 95, 92, 100);
    assert!(ids.length() == 6);
    i = 0;
    while (i < 6) {
        assert!(price_of(ids[i]) == 95 - i / 2);
        i = i + 1;
    };
    // The range may start below the best ask and run past the worst one.
    let (ids, _) = book.inspect_orders(ASK, 1, 1_000, 100);
    assert!(ids.length() == 40);
    // An empty range.
    let (ids, _) = book.inspect_orders(ASK, 110, 110, 100);
    assert!(ids.is_empty());
    done(book);
}

#[test]
fun inspect_orders_caps_the_limit_at_fifty() {
    let mut book = new_book();
    ladder(&mut book);
    let (ids, _) = book.inspect_orders(ASK, 100, 1_000, 0);
    assert!(ids.is_empty());
    let (ids, _) = book.inspect_orders(ASK, 100, 1_000, 3);
    assert!(ids.length() == 3);
    let (ids, _) = book.inspect_orders(ASK, 100, 1_000, 1_000);
    assert!(ids.length() == 40);
    // Add more asks than the cap and check it holds.
    let mut i = 0;
    while (i < 20) {
        post(&mut book, 1, ASK, 1, 130 + i);
        i = i + 1;
    };
    let (ids, _) = book.inspect_orders(ASK, 100, 1_000, 1_000);
    assert!(ids.length() == 50);
    done(book);
}

// === Parameters ===

#[test, expected_failure(abort_code = 3001, location = perpetuals::orderbook)]
fun orderbook_rejects_large_branches() {
    let ctx = &mut tx_context::dummy();
    let book = ob::create_orderbook(2, 4, 201, 2, 3, 3, ctx);
    done(book);
}

#[test, expected_failure(abort_code = 3001, location = perpetuals::orderbook)]
fun orderbook_rejects_large_leaves() {
    let ctx = &mut tx_context::dummy();
    let book = ob::create_orderbook(2, 4, 4, 2, 3, 201, ctx);
    done(book);
}
