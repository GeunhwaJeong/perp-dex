// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Oracle source whose prices are pushed by hand, standing in for Pyth on localnet. It uses the
/// same `oracle_aggregator` entry points as `oracle_pyth`, with the `Source` object itself as the
/// feed's price object.
module perp_e2e::mock_source;

use authority_cap::authority::AuthorityCap;
use haneul::clock::Clock;
use oracle_aggregator::authority::{PACKAGE, VENDOR};
use oracle_aggregator::config::Config;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use oracle_aggregator::source::{Self, Source};

const EPriceNotApplied: u64 = 0;

public struct MOCK has drop {}

public fun create<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
): Source<MOCK> {
    source::create(config, cap, &MOCK {}, 1)
}

public fun authorize<ADMIN_OR_ASSISTANT>(
    source: &mut Source<MOCK>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    source.set_authorized(config, cap, true)
}

public fun new_price_feed<VendorKey, ADMIN_OR_ASSISTANT>(
    source: &Source<MOCK>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    pfs: &mut PriceFeedStorage,
    price: u128,
    twap_period_ms: u64,
    clock: &Clock,
) {
    pfs.new_price_feed(
        cap,
        config,
        source.borrow_source_cap(MOCK {}),
        source,
        price,
        clock.timestamp_ms(),
        twap_period_ms,
    )
}

/// `update_price_feed` silently skips an update whose timestamp is not newer than the stored one,
/// so this aborts instead when the new price did not land.
public fun set_price(
    source: &Source<MOCK>,
    config: &Config,
    pfs: &mut PriceFeedStorage,
    price: u128,
    clock: &Clock,
) {
    pfs.update_price_feed(
        config,
        source.borrow_source_cap(MOCK {}),
        source,
        price,
        clock.timestamp_ms(),
    );
    assert!(pfs.price_feed(source.source_id()).price() == price, EPriceNotApplied);
}
