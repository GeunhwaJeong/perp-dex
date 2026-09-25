// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::price;

use haneul::clock::Clock;
use oracle_aggregator::config::Config;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use std::u128;
use std::u64;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const ENoSources: vector<u8> = b"There are no source feeds to query.";
#[error(code = 1)]
const ENoValidPrices: vector<u8> = b"There are no valid prices to query.";
#[error(code = 2)]
const ETooManyPriceFeedsForMedian: vector<u8> =
    b"Median price calculation supports at most three price feeds.";

// === Functions ===

public fun valid_prices_from_sources(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): vector<u128> {
    config.assert_package_version();
    if (source_ids.length() == 0) {
        if (may_abort) abort ENoSources;
        return vector[]
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut prices = vector[];
    source_ids.do!(|source_id| {
        let (price, timestamp_ms) = price_feed_storage[source_id].price_and_timestamp_ms();
        let is_valid = price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) prices.push_back(price);
    });
    if (prices.is_empty() && may_abort) abort ENoValidPrices;
    prices
}

public fun valid_twap_prices_from_sources(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): vector<u128> {
    config.assert_package_version();
    if (source_ids.length() == 0) {
        if (may_abort) abort ENoSources;
        return vector[]
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut twap_prices = vector[];
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        let is_valid = twap_price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) twap_prices.push_back(twap_price);
    });
    if (twap_prices.is_empty() && may_abort) abort ENoValidPrices;
    twap_prices
}

public fun valid_prices_and_twap_prices_from_sources(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (vector<u128>, vector<u128>) {
    config.assert_package_version();
    if (source_ids.length() == 0) {
        if (may_abort) abort ENoSources;
        return (vector[], vector[])
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut prices = vector[];
    let mut twap_prices = vector[];
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let price = feed.price();
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        if (min_timestamp_ms <= timestamp_ms) {
            if (price != 0) prices.push_back(price);
            if (twap_price != 0) twap_prices.push_back(twap_price);
        };
    });
    if ((prices.is_empty() || twap_prices.is_empty()) && may_abort) abort ENoValidPrices;
    (prices, twap_prices)
}

public fun newest_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return 0
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_price, mut newest_timestamp_ms) = (0, u64::max_value!());
    source_ids.do!(|source_id| {
        let (price, timestamp_ms) = price_feed_storage[source_id].price_and_timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_price, newest_timestamp_ms) = (price, timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    newest_price
}

public fun newest_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return 0
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_twap_price, mut newest_timestamp_ms) = (0, u64::max_value!());
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let timestamp_ms = feed.timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_twap_price, newest_timestamp_ms) = (feed.twap_price(), timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    newest_twap_price
}

public fun newest_price_and_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (u128, u128) {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return (0, 0)
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_price, mut newest_twap_price, mut newest_timestamp_ms) =
        (0, 0, u64::max_value!());
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let timestamp_ms = feed.timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_price, newest_twap_price, newest_timestamp_ms) =
                    (feed.price(), feed.twap_price(), timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    (newest_price, newest_twap_price)
}

public fun median_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    clock: &Clock,
): u128 {
    median_of(valid_prices_from_sources(
        price_feed_storage,
        config,
        source_ids,
        staleness_threshold_ms,
        true,
        clock,
    ))
}

public fun median_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (source_ids.length() == 0) abort ENoSources;

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // The median supports at most three feeds: a fourth valid TWAP price aborts.
    let (mut first_twap_price, mut second_twap_price, mut third_twap_price, mut twap_price_count) =
        (0, 0, 0, 0u64);
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        let is_valid = twap_price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) {
            if (twap_price_count == 0) {
                first_twap_price = twap_price;
            } else if (twap_price_count == 1) {
                second_twap_price = twap_price;
            } else {
                assert!(twap_price_count == 2, ETooManyPriceFeedsForMedian);
                third_twap_price = twap_price;
            };
            twap_price_count = twap_price_count + 1;
        };
    });
    if (twap_price_count == 0) abort ENoValidPrices;

    // Same selection as `median_of`.
    if (twap_price_count == 1) {
        first_twap_price
    } else if (twap_price_count == 2) {
        u128::max(first_twap_price, second_twap_price)
    } else {
        let a = first_twap_price;
        let b = second_twap_price;
        let c = third_twap_price;
        u128::max(u128::min(u128::max(a, b), c), u128::min(a, b))
    }
}

public fun median_price_and_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    clock: &Clock,
): (u128, u128) {
    config.assert_package_version();
    if (source_ids.length() == 0) abort ENoSources;

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // The median supports at most three feeds: a fourth valid price or TWAP price aborts.
    let (mut first_price, mut second_price, mut third_price, mut price_count) = (0, 0, 0, 0u64);
    let (mut first_twap_price, mut second_twap_price, mut third_twap_price, mut twap_price_count) =
        (0, 0, 0, 0u64);
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let price = feed.price();
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        if (min_timestamp_ms <= timestamp_ms) {
            if (price != 0) {
                if (price_count == 0) {
                    first_price = price;
                } else if (price_count == 1) {
                    second_price = price;
                } else {
                    assert!(price_count == 2, ETooManyPriceFeedsForMedian);
                    third_price = price;
                };
                price_count = price_count + 1;
            };
            if (twap_price != 0) {
                if (twap_price_count == 0) {
                    first_twap_price = twap_price;
                } else if (twap_price_count == 1) {
                    second_twap_price = twap_price;
                } else {
                    assert!(twap_price_count == 2, ETooManyPriceFeedsForMedian);
                    third_twap_price = twap_price;
                };
                twap_price_count = twap_price_count + 1;
            };
        };
    });
    if (price_count == 0 || twap_price_count == 0) abort ENoValidPrices;

    // Same selection as `median_of`.
    let median_price = if (price_count == 1) {
        first_price
    } else if (price_count == 2) {
        u128::max(first_price, second_price)
    } else {
        let a = first_price;
        let b = second_price;
        let c = third_price;
        u128::max(u128::min(u128::max(a, b), c), u128::min(a, b))
    };
    let median_twap_price = if (twap_price_count == 1) {
        first_twap_price
    } else if (twap_price_count == 2) {
        u128::max(first_twap_price, second_twap_price)
    } else {
        let a = first_twap_price;
        let b = second_twap_price;
        let c = third_twap_price;
        u128::max(u128::min(u128::max(a, b), c), u128::min(a, b))
    };
    (median_price, median_twap_price)
}

public fun average_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (source_ids.length() == 0) {
        if (may_abort) abort ENoSources;
        return 0
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut twap_price_sum = 0u256;
    let mut count = 0u64;
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        let is_valid = twap_price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) {
            twap_price_sum = twap_price_sum + (twap_price as u256);
            count = count + 1;
        };
    });
    if (count == 0 && may_abort) abort ENoValidPrices;
    // With no valid price (and `may_abort` unset) this divides by one and returns zero.
    ((twap_price_sum / (count.max(1) as u256)) as u128)
}

public fun average_price_and_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (u128, u128) {
    config.assert_package_version();
    if (source_ids.length() == 0) {
        if (may_abort) abort ENoSources;
        return (0, 0)
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut price_sum = 0u256;
    let mut twap_price_sum = 0u256;
    let mut price_count = 0u64;
    let mut twap_price_count = 0u64;
    source_ids.do!(|source_id| {
        let feed = &price_feed_storage[source_id];
        let price = feed.price();
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        if (min_timestamp_ms <= timestamp_ms) {
            if (price != 0) {
                price_sum = price_sum + (price as u256);
                price_count = price_count + 1;
            };
            if (twap_price != 0) {
                twap_price_sum = twap_price_sum + (twap_price as u256);
                twap_price_count = twap_price_count + 1;
            };
        };
    });
    if ((price_count == 0 || twap_price_count == 0) && may_abort) abort ENoValidPrices;
    (
        ((price_sum / (price_count.max(1) as u256)) as u128),
        ((twap_price_sum / (twap_price_count.max(1) as u256)) as u128),
    )
}

public fun average_reciprocal_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    let twap_price = average_twap_price_from_sources_(
        price_feed_storage,
        config,
        source_ids,
        staleness_threshold_ms,
        may_abort,
        clock,
    );
    if (twap_price == 0) return 0;
    // Prices carry 18 decimals, so 1e36 / price is the reciprocal at the same scale.
    ((1_000_000_000_000_000_000_000_000_000_000_000_000u256 / (twap_price as u256)) as u128)
}

public fun average_reciprocal_price_and_twap_price_from_sources_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    source_ids: vector<u16>,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (u128, u128) {
    let (price, twap_price) = average_price_and_twap_price_from_sources_(
        price_feed_storage,
        config,
        source_ids,
        staleness_threshold_ms,
        may_abort,
        clock,
    );
    // Prices carry 18 decimals, so 1e36 / price is the reciprocal at the same scale.
    (
        if (price == 0) {
            0
        } else {
            ((1_000_000_000_000_000_000_000_000_000_000_000_000u256 / (price as u256)) as u128)
        },
        if (twap_price == 0) {
            0
        } else {
            ((1_000_000_000_000_000_000_000_000_000_000_000_000u256 / (twap_price as u256)) as u128)
        },
    )
}

public fun valid_prices_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): vector<u128> {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return vector[]
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut prices = vector[];
    price_feed_storage.feeds().do_ref!(|feed| {
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        let is_valid = price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) prices.push_back(price);
    });
    if (prices.is_empty() && may_abort) abort ENoValidPrices;
    prices
}

public fun valid_twap_prices_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): vector<u128> {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return vector[]
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut twap_prices = vector[];
    price_feed_storage.feeds().do_ref!(|feed| {
        let twap_price = feed.twap_price();
        let timestamp_ms = feed.timestamp_ms();
        let is_valid = twap_price != 0 && {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_valid) twap_prices.push_back(twap_price);
    });
    if (twap_prices.is_empty() && may_abort) abort ENoValidPrices;
    twap_prices
}

public fun valid_prices_and_twap_prices_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (vector<u128>, vector<u128>) {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return (vector[], vector[])
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    let mut prices = vector[];
    let mut twap_prices = vector[];
    price_feed_storage.feeds().do_ref!(|feed| {
        let (price, timestamp_ms, twap_price) = feed.price_timestamp_ms_twap_price();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (price != 0) prices.push_back(price);
            if (twap_price != 0) twap_prices.push_back(twap_price);
        };
    });
    if ((prices.is_empty() || twap_prices.is_empty()) && may_abort) abort ENoValidPrices;
    (prices, twap_prices)
}

public fun newest_price_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return 0
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_price, mut newest_timestamp_ms) = (0, u64::max_value!());
    price_feed_storage.feeds().do_ref!(|feed| {
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_price, newest_timestamp_ms) = (price, timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    newest_price
}

public fun newest_twap_price_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): u128 {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return 0
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_twap_price, mut newest_timestamp_ms) = (0, u64::max_value!());
    price_feed_storage.feeds().do_ref!(|feed| {
        let timestamp_ms = feed.timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_twap_price, newest_timestamp_ms) = (feed.twap_price(), timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    newest_twap_price
}

public fun newest_price_and_twap_price_(
    price_feed_storage: &PriceFeedStorage,
    config: &Config,
    staleness_threshold_ms: u64,
    may_abort: bool,
    clock: &Clock,
): (u128, u128) {
    config.assert_package_version();
    if (price_feed_storage.size() == 0) {
        if (may_abort) abort ENoSources;
        return (0, 0)
    };

    let now_ms = clock.timestamp_ms();
    let staleness_ms = now_ms.min(staleness_threshold_ms);
    let min_timestamp_ms = now_ms - staleness_ms;
    // `u64::max_value!()` as the newest timestamp means no fresh feed has been seen yet.
    let (mut newest_price, mut newest_twap_price, mut newest_timestamp_ms) =
        (0, 0, u64::max_value!());
    price_feed_storage.feeds().do_ref!(|feed| {
        let timestamp_ms = feed.timestamp_ms();
        let is_fresh = {
            let timestamp_ms = timestamp_ms;
            min_timestamp_ms <= timestamp_ms
        };
        if (is_fresh) {
            if (newest_timestamp_ms == u64::max_value!() || timestamp_ms > newest_timestamp_ms) {
                (newest_price, newest_twap_price, newest_timestamp_ms) =
                    (feed.price(), feed.twap_price(), timestamp_ms);
            };
        };
    });
    if (newest_timestamp_ms == u64::max_value!() && may_abort) abort ENoValidPrices;
    (newest_price, newest_twap_price)
}

public fun median_of(prices: vector<u128>): u128 {
    let len = prices.length();
    if (len == 0) abort ENoValidPrices;
    if (len == 1) {
        prices[0]
    } else if (len == 2) {
        // Two prices have no middle element; the higher one is used.
        u128::max(prices[0], prices[1])
    } else {
        assert!(len == 3, ETooManyPriceFeedsForMedian);
        let a = prices[0];
        let b = prices[1];
        let c = prices[2];
        u128::max(u128::min(u128::max(a, b), c), u128::min(a, b))
    }
}
