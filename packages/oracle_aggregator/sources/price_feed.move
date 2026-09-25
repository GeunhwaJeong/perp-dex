// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::price_feed;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EPriceFeedAlreadyExists: vector<u8> =
    b"A price feed already exists for the provided source.";
#[error(code = 1)]
const EPriceFeedDoesNotExist: vector<u8> =
    b"A price feed does not exist for the provided source.";
#[error(code = 2)]
const EInvalidTwapPeriodMs: vector<u8> = b"The TWAP period must be greater than zero.";
#[error(code = 3)]
const EInvalidPrice: vector<u8> = b"Price must be non-zero";

// === Types ===

public struct PriceFeed has drop, store {
    source_id: u16,
    from: ID,
    price: u128,
    timestamp_ms: u64,
    twap_price: u128,
    twap_period_ms: u64,
}

// === Functions ===

public(package) fun new(
    source_id: u16,
    from: ID,
    price: u128,
    timestamp_ms: u64,
    twap_period_ms: u64,
): PriceFeed {
    assert!(twap_period_ms > 0, EInvalidTwapPeriodMs);
    assert!(price != 0, EInvalidPrice);
    PriceFeed { source_id, from, price, timestamp_ms, twap_price: price, twap_period_ms }
}

public fun source_id(feed: &PriceFeed): u16 {
    feed.source_id
}

public fun from(feed: &PriceFeed): ID {
    feed.from
}

public fun price(feed: &PriceFeed): u128 {
    feed.price
}

public fun timestamp_ms(feed: &PriceFeed): u64 {
    feed.timestamp_ms
}

public fun price_and_timestamp_ms(feed: &PriceFeed): (u128, u64) {
    (feed.price, feed.timestamp_ms)
}

public fun twap_price(feed: &PriceFeed): u128 {
    feed.twap_price
}

public fun twap_period_ms(feed: &PriceFeed): u64 {
    feed.twap_period_ms
}

public(package) fun as_parts(feed: &PriceFeed): (
    u128, /* price */
    u64,  /* timestamp_ms */
    u128, /* twap_price */
    u64,  /* twap_period_ms */
) {
    (feed.price, feed.timestamp_ms, feed.twap_price, feed.twap_period_ms)
}

public(package) fun price_timestamp_ms_twap_price(feed: &PriceFeed): (
    u128, /* price */
    u64,  /* timestamp_ms */
    u128, /* twap_price */
) {
    (feed.price, feed.timestamp_ms, feed.twap_price)
}

public(package) fun borrow_feed(feeds: &vector<PriceFeed>, source_id: u16): &PriceFeed {
    let (found, index) = binary_search(feeds, source_id);
    assert!(found, EPriceFeedDoesNotExist);
    &feeds[index]
}

public(package) fun borrow_feed_mut(
    feeds: &mut vector<PriceFeed>,
    source_id: u16,
): &mut PriceFeed {
    let (found, index) = binary_search(feeds, source_id);
    assert!(found, EPriceFeedDoesNotExist);
    &mut feeds[index]
}

/// `feeds` is kept sorted by `source_id`. Returns whether `source_id` is present and its index,
/// or the index at which it would have to be inserted to keep the order.
public(package) fun binary_search(feeds: &vector<PriceFeed>, source_id: u16): (bool, u64) {
    let mut low = 0;
    let mut high = feeds.length();
    while (low < high) {
        let mid = (low + high) >> 1;
        if (feeds[mid].source_id < source_id) {
            low = mid + 1;
        } else {
            high = mid;
        }
    };
    let found = low < feeds.length() && feeds[low].source_id == source_id;
    (found, low)
}

public(package) fun contains(feeds: &vector<PriceFeed>, source_id: u16): bool {
    let (found, _) = binary_search(feeds, source_id);
    found
}

public(package) fun add_feed(
    feeds: &mut vector<PriceFeed>,
    source_id: u16,
    from: ID,
    price: u128,
    timestamp_ms: u64,
    twap_period_ms: u64,
) {
    let (found, index) = binary_search(feeds, source_id);
    assert!(!found, EPriceFeedAlreadyExists);
    feeds.insert(new(source_id, from, price, timestamp_ms, twap_period_ms), index)
}

public(package) fun remove_feed(feeds: &mut vector<PriceFeed>, source_id: u16) {
    let (found, index) = binary_search(feeds, source_id);
    assert!(found, EPriceFeedDoesNotExist);
    feeds.remove(index);
}

public(package) fun maybe_set_price(
    price_feed: &mut PriceFeed,
    price: u128,
    timestamp_ms: u64,
): bool {
    if (timestamp_ms <= price_feed.timestamp_ms || price == 0) {
        return false
    };
    price_feed.twap_price = update_twap(
        price,
        price_feed.twap_price,
        timestamp_ms,
        price_feed.timestamp_ms,
        price_feed.twap_period_ms,
    );
    price_feed.price = price;
    price_feed.timestamp_ms = timestamp_ms;
    true
}

public(package) fun set_feed_twap_period_ms(
    price_feed: &mut PriceFeed,
    twap_period_ms: u64,
): u64 {
    assert!(twap_period_ms > 0, EInvalidTwapPeriodMs);
    let old_twap_period_ms = price_feed.twap_period_ms;
    price_feed.twap_period_ms = twap_period_ms;
    old_twap_period_ms
}

/// Time-weighted moving average over a `twap_period_ms` window: the new price is weighted by the
/// time elapsed since the last update and the previous TWAP by the rest of the window. An update
/// in the same millisecond counts as 1 ms, and once a whole window has elapsed the previous TWAP
/// keeps a weight of 1 ms against `elapsed_ms` for the new price.
public(package) fun update_twap(
    price_now: u128,
    last_twap: u128,
    time_now_ms: u64,
    last_timestamp_ms: u64,
    twap_period_ms: u64,
): u128 {
    let price = (price_now as u256);
    let twap = (last_twap as u256);
    if (time_now_ms == last_timestamp_ms) {
        if (twap_period_ms <= 1) {
            return (((price + twap) / 2) as u128)
        };
        return (((price + twap * ((twap_period_ms - 1) as u256))
            / (twap_period_ms as u256)) as u128)
    };

    let elapsed_ms = time_now_ms - last_timestamp_ms;
    if (twap_period_ms <= elapsed_ms) {
        return (((price * (elapsed_ms as u256) + twap) / ((elapsed_ms + 1) as u256)) as u128)
    };
    (((price * (elapsed_ms as u256) + twap * ((twap_period_ms - elapsed_ms) as u256))
        / (twap_period_ms as u256)) as u128)
}
