// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator_pyth_integration::price_feed_storage;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::dynamic_field;
use oracle_aggregator::{
    authority::{Self as oracle_authority, PACKAGE, VENDOR},
    config::Config,
    price_feed_storage::PriceFeedStorage,
    source::Source,
};
use oracle_aggregator_pyth_integration::source::{Self as pyth_source, PYTH};
use pyth::{
    i64::I64,
    price::Price,
    price_info::PriceInfoObject,
    pyth,
};
use std::u128;
use std::u256;

use fun oracle_aggregator_pyth_integration::source::assert_version as Source.assert_version;
use fun oracle_aggregator_pyth_integration::source::source_cap as Source.source_cap;

// === Errors and constants ===

#[error(code = 0)]
const EUnsupportedExponent: vector<u8> =
    b"Pyth integration: the feed's exponent is too large for the price to be representable.";
#[error(code = 1)]
const EPriceOverflow: vector<u8> =
    b"Pyth integration: the normalized price does not fit into a u128.";
#[error(code = 2)]
const EConfidenceTooWide: vector<u8> =
    b"Pyth integration: the price's confidence interval is wider than the source allows.";
#[error(code = 3)]
const EInvalidConfidenceBound: vector<u8> =
    b"Pyth integration: the confidence bound is in basis points of the price, at most 10,000.";

/// Widest confidence interval accepted until the package admin sets one: 1% of the price.
const DEFAULT_MAX_CONFIDENCE_BPS: u64 = 100;
const BPS: u128 = 10_000;

// === Types ===

/// The source's confidence bound, kept on the `Source<PYTH>` object.
public struct MaxConfidenceBpsKey has copy, drop, store {}

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
    let (price, timestamp_ms) = accepted_price(source, &pyth_price);
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
    let (price, timestamp_ms) = accepted_price(source, &pyth_price);
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

/// Sets the widest confidence interval the source accepts, in basis points of the price. A
/// price whose interval is wider is refused rather than written, leaving the feed stale so that
/// markets stop on `EBadIndexPrice` instead of trading on an uncertain price.
public fun set_max_confidence_bps<ADMIN_OR_ASSISTANT>(
    source: &mut Source<PYTH>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_confidence_bps: u64,
) {
    source.assert_version();
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);
    assert!(max_confidence_bps <= (BPS as u64), EInvalidConfidenceBound);
    let id = source.borrow_mut_id(pyth_source::witness());
    if (dynamic_field::exists(id, MaxConfidenceBpsKey {})) {
        *dynamic_field::borrow_mut(id, MaxConfidenceBpsKey {}) = max_confidence_bps
    } else {
        dynamic_field::add(id, MaxConfidenceBpsKey {}, max_confidence_bps)
    }
}

/// The source's confidence bound in basis points of the price.
public fun max_confidence_bps(source: &Source<PYTH>): u64 {
    let id = source.borrow_id();
    if (!dynamic_field::exists(id, MaxConfidenceBpsKey {})) return DEFAULT_MAX_CONFIDENCE_BPS;
    *dynamic_field::borrow(id, MaxConfidenceBpsKey {})
}

/// The 18-decimal price and millisecond timestamp of a Pyth price the source accepts: positive
/// (a negative one aborts in `get_magnitude_if_positive`) and with a confidence interval within
/// the source's bound. Price and interval share the exponent, so the bound is checked on the raw
/// magnitudes.
fun accepted_price(source: &Source<PYTH>, pyth_price: &Price): (u128, u64) {
    let magnitude = pyth_price.get_price().get_magnitude_if_positive();
    assert!(
        (pyth_price.get_conf() as u128) * BPS
            <= (magnitude as u128) * (max_confidence_bps(source) as u128),
        EConfidenceTooWide,
    );
    (
        scaled_by_exponent(magnitude, pyth_price.get_expo()),
        pyth_price.get_timestamp() * 1000,
    )
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
