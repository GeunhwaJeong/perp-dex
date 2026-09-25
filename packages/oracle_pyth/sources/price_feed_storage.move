// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator_pyth_integration::price_feed_storage;

use authority_cap::authority::{ADMIN, AuthorityCap};
use oracle_aggregator::{
    authority::{PACKAGE, VENDOR},
    config::Config,
    price_feed_storage::PriceFeedStorage,
    source::Source,
};
use oracle_aggregator_pyth_integration::source::PYTH;
use pyth::{
    i64::I64,
    price_info::PriceInfoObject,
    pyth,
};
use std::u128;
use std::u256;

use fun oracle_aggregator_pyth_integration::source::assert_version as Source.assert_version;
use fun oracle_aggregator_pyth_integration::source::source_cap as Source.source_cap;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EUnsupportedExponent: vector<u8> =
    b"Pyth integration: the feed's exponent is too large for the price to be representable.";
#[error(code = 1)]
const EPriceOverflow: vector<u8> =
    b"Pyth integration: the normalized price does not fit into a u128.";

// === Functions ===

public fun new_price_feed<VendorKey, ADMIN_OR_ASSISTANT>(
    source: &Source<PYTH>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    pyth_price_info: &PriceInfoObject,
    twap_period_ms: u64,
) {
    source.assert_version();
    let pyth_price = pyth::get_price_unsafe(pyth_price_info);
    // A negative Pyth price aborts in `get_magnitude_if_positive`.
    let price = {
        let pyth_price = pyth_price;
        scaled_by_exponent(
            pyth_price.get_price().get_magnitude_if_positive(),
            pyth_price.get_expo(),
        )
    };
    let timestamp_ms = {
        let pyth_price = pyth_price;
        pyth_price.get_timestamp() * 1000
    };
    price_feed_storage.new_price_feed(
        cap,
        config,
        source.source_cap(),
        pyth_price_info,
        price,
        timestamp_ms,
        twap_period_ms,
    )
}

public fun update_price_feed(
    source: &Source<PYTH>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    pyth_price_info: &PriceInfoObject,
) {
    source.assert_version();
    let pyth_price = pyth::get_price_unsafe(pyth_price_info);
    // A negative Pyth price aborts in `get_magnitude_if_positive`.
    let price = {
        let pyth_price = pyth_price;
        scaled_by_exponent(
            pyth_price.get_price().get_magnitude_if_positive(),
            pyth_price.get_expo(),
        )
    };
    let timestamp_ms = {
        let pyth_price = pyth_price;
        pyth_price.get_timestamp() * 1000
    };
    price_feed_storage.update_price_feed(
        config,
        source.source_cap(),
        pyth_price_info,
        price,
        timestamp_ms,
    )
}

public fun set_twap_period_ms<VendorKey, ADMIN_OR_MAINTENANCE>(
    source: &Source<PYTH>,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_MAINTENANCE>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    twap_period_ms: u64,
) {
    source.assert_version();
    price_feed_storage.set_twap_period_ms(authority_cap, config, source.source_id(), twap_period_ms)
}

public fun remove_price_feed<VendorKey>(
    source: &Source<PYTH>,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
) {
    source.assert_version();
    price_feed_storage.remove_price_feed(authority_cap, config, source.source_cap())
}

public fun force_remove_price_feed<ADMIN_OR_ASSISTANT>(
    source: &Source<PYTH>,
    authority_cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
) {
    source.assert_version();
    price_feed_storage.force_remove_price_feed(authority_cap, config, source.source_id())
}

/// Converts a Pyth price `magnitude * 10^exponent` into an 18-decimal fixed-point `u128`.
public(package) fun scaled_by_exponent(
    magnitude: u64,
    exponent: I64,
): u128 {
    if (exponent.get_is_negative()) {
        let decimals = exponent.get_magnitude_if_negative();
        // `magnitude * 1e18` is below 10^38, so the result would be zero anyway.
        if (decimals >= 38) return 0;
        let divisor = u256::pow(10, (decimals as u8));
        return (((magnitude as u256) * 1_000_000_000_000_000_000 / divisor) as u128)
    };

    let power = exponent.get_magnitude_if_positive();
    assert!(power <= 20, EUnsupportedExponent);
    let scaled = (magnitude as u256) * u256::pow(10, (power as u8)) * 1_000_000_000_000_000_000;
    assert!(scaled <= (u128::max_value!() as u256), EPriceOverflow);
    (scaled as u128)
}
