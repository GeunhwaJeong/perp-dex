// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for the Pyth adapter: the exponent scaling that turns a Pyth `magnitude * 10^expo`
/// price into an 18-decimal value, and the feed creation and update path through a
/// `PriceInfoObject` built with Pyth's test-only constructor.
///
/// Pyth exposes no test-only way to change the price inside an existing `PriceInfoObject`, so
/// the update path is checked for what the adapter itself decides: the feed stays bound to the
/// object it was created with, a re-push of the same object is a silent no-op, and the source
/// must be authorized. Price changes through `maybe_set_price` are covered by the aggregator's
/// mock source in the perpetuals tests.
#[test_only]
module oracle_aggregator_pyth_integration::pyth_adapter_tests;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::test_scenario::{Self as ts, Scenario};
use oracle_aggregator::config::Config as OracleConfig;
use oracle_aggregator::init as oracle_init;
use oracle_aggregator::price_feed_storage::{Self as agg, PriceFeedStorage};
use oracle_aggregator::source::Source;
use oracle_aggregator_pyth_integration::price_feed_storage as adapter;
use oracle_aggregator_pyth_integration::source::{Self as pyth_source, PYTH};
use pyth::i64;
use pyth::price;
use pyth::price_feed;
use pyth::price_identifier;
use pyth::price_info::{Self, PriceInfoObject};
use vendor::config::{Self as vendor_config, Config as VendorConfig};
use vendor::init as vendor_init;
use vendor::metadata::{Self, VendorMetadata};

const ONE: u256 = 1_000_000_000_000_000_000;

public struct VK has drop {}

// === Exponent scaling ===

#[test]
fun negative_exponents_scale_down() {
    // A typical BTC feed: 65,000.12345678 with expo -8.
    assert!(adapter::scaled_by_exponent(6_500_012_345_678, i64::new(8, true)) == 65_000_123_456_780_000_000_000);
    // One unit at expo -18 is the smallest representable value.
    assert!(adapter::scaled_by_exponent(1, i64::new(18, true)) == 1);
    // Below the resolution the value rounds down to zero.
    assert!(adapter::scaled_by_exponent(1, i64::new(19, true)) == 0);
    // 10^19 at expo -37 is exactly one unit.
    assert!(adapter::scaled_by_exponent(10_000_000_000_000_000_000, i64::new(37, true)) == 1);
    // From 38 decimals on the result is zero regardless of the magnitude.
    assert!(adapter::scaled_by_exponent(18_446_744_073_709_551_615, i64::new(38, true)) == 0);
    assert!(adapter::scaled_by_exponent(18_446_744_073_709_551_615, i64::new(200, true)) == 0);
}

#[test]
fun zero_and_positive_exponents_scale_up() {
    assert!(adapter::scaled_by_exponent(65_000, i64::new(0, false)) == (65_000 * ONE as u128));
    assert!(adapter::scaled_by_exponent(65, i64::new(3, false)) == (65_000 * ONE as u128));
    // 1 * 10^20 * 10^18 is the largest power that fits with a magnitude of one.
    assert!(adapter::scaled_by_exponent(1, i64::new(20, false)) == 100_000_000_000_000_000_000_000_000_000_000_000_000);
    assert!(adapter::scaled_by_exponent(0, i64::new(20, false)) == 0);
}

#[test, expected_failure(abort_code = adapter::EUnsupportedExponent)]
fun exponents_above_twenty_are_refused() {
    adapter::scaled_by_exponent(1, i64::new(21, false));
}

#[test, expected_failure(abort_code = adapter::EPriceOverflow)]
fun prices_beyond_u128_are_refused() {
    adapter::scaled_by_exponent(10, i64::new(20, false));
}

// === Fixture ===

public struct Fx {
    admin: address,
    vendor_cap: AuthorityCap<vendor::authority::VENDOR<VK>, ADMIN>,
    oracle_admin: AuthorityCap<oracle_aggregator::authority::PACKAGE, ADMIN>,
    oracle_vk: AuthorityCap<oracle_aggregator::authority::VENDOR<VK>, ADMIN>,
    metadata: VendorMetadata<VK>,
    source: Source<PYTH>,
    pfs: ID,
}

fun setup(): (Scenario, Fx) {
    let admin = @0xAD;
    let mut sc = ts::begin(admin);
    vendor_init::init_for_testing(sc.ctx());
    oracle_init::init_for_testing(sc.ctx());
    sc.next_tx(admin);
    let vendor_pkg_admin = sc.take_from_sender<AuthorityCap<vendor::authority::PACKAGE, ADMIN>>();
    let oracle_admin = sc.take_from_sender<AuthorityCap<oracle_aggregator::authority::PACKAGE, ADMIN>>();
    let mut vconfig = sc.take_shared<VendorConfig>();
    let mut oconfig = sc.take_shared<OracleConfig>();
    let vendor_cap = vendor_config::register_vendor_for_testing<VK, ADMIN>(&mut vconfig, &vendor_pkg_admin);
    let mut md = metadata::new<VK, ADMIN>(
        &mut vconfig, &vendor_cap, b"Pyth tests".to_ascii_string(), b"".to_ascii_string(),
    );
    md.approve_domain_registration<VK, oracle_aggregator::authority::PACKAGE>(&vconfig, &oracle_admin);
    let oracle_vk = oconfig.register_vendor<VK, ADMIN>(&vendor_cap, &vconfig, &md);
    let mut source = pyth_source::create<ADMIN>(&mut oconfig, &oracle_admin);
    pyth_source::authorize(&mut source, &oconfig, &oracle_admin);
    let pfs = agg::new<VK, ADMIN>(&mut oconfig, &oracle_vk, b"BTC/USD".to_string());
    let pfs_id = object::id(&pfs);
    transfer::public_share_object(pfs);
    ts::return_shared(vconfig);
    ts::return_shared(oconfig);
    sc.return_to_sender(vendor_pkg_admin);
    (sc, Fx { admin, vendor_cap, oracle_admin, oracle_vk, metadata: md, source, pfs: pfs_id })
}

fun finish(sc: Scenario, fx: Fx) {
    let Fx { admin: _, vendor_cap, oracle_admin, oracle_vk, metadata, source, pfs: _ } = fx;
    transfer::public_transfer(vendor_cap, @0x0);
    transfer::public_transfer(oracle_admin, @0x0);
    transfer::public_transfer(oracle_vk, @0x0);
    transfer::public_transfer(metadata, @0x0);
    transfer::public_transfer(source, @0x0);
    sc.end();
}

/// A Pyth price object carrying `magnitude * 10^-expo_decimals` at `timestamp_s`.
fun pyth_object(sc: &mut Scenario, magnitude: u64, negative: bool, expo_decimals: u64, timestamp_s: u64): PriceInfoObject {
    let p = price::new(i64::new(magnitude, negative), 0, i64::new(expo_decimals, expo_decimals != 0), timestamp_s);
    let feed = price_feed::new(
        price_identifier::from_byte_vec(x"e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"),
        p,
        p,
    );
    price_info::new_price_info_object_for_test(price_info::new_price_info(timestamp_s, timestamp_s, feed), sc.ctx())
}

/// Deauthorizes the fixture's source with the package admin cap.
fun deauthorize_source(sc: &mut Scenario, fx: &mut Fx) {
    sc.next_tx(fx.admin);
    let oconfig = sc.take_shared<OracleConfig>();
    let Fx { source, oracle_admin, .. } = fx;
    pyth_source::deauthorize(source, &oconfig, oracle_admin);
    ts::return_shared(oconfig);
}

/// Bumps the fixture's source version with the package admin cap.
fun bump_source_version(sc: &mut Scenario, fx: &mut Fx, version: u64) {
    sc.next_tx(fx.admin);
    let oconfig = sc.take_shared<OracleConfig>();
    let Fx { source, oracle_admin, .. } = fx;
    source.upgrade_version(&oconfig, oracle_admin, version);
    ts::return_shared(oconfig);
}

/// Runs `$f` with the oracle config and the storage.
macro fun with_storage($sc: &mut Scenario, $fx: &Fx, $f: |&OracleConfig, &mut PriceFeedStorage|) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin);
    let oconfig = sc.take_shared<OracleConfig>();
    let mut pfs = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs);
    $f(&oconfig, &mut pfs);
    ts::return_shared(oconfig);
    ts::return_shared(pfs);
}

// === Feed creation ===

#[test]
fun new_price_feed_stores_the_scaled_price_and_millisecond_timestamp() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        assert!(pfs.contains(source_id) && pfs.size() == 1);
        let feed = pfs.price_feed(source_id);
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        assert!(price == (65_000 * ONE as u128));
        assert!(timestamp_ms == 1_700_000_000_000);
        assert!(feed.twap_price() == price && feed.twap_period_ms() == 60_000);
        assert!(feed.from() == object::id(&obj));
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = 0, location = pyth::i64)]
fun a_negative_pyth_price_is_refused() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, true, 8, 1_700_000_000);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = agg::ESourceNotAuthorized)]
fun an_unauthorized_source_cannot_create_feeds() {
    let (mut sc, mut fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    deauthorize_source(&mut sc, &mut fx);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

// === Feed updates ===

#[test]
fun re_pushing_the_same_object_is_a_no_op() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        // Same timestamp: the aggregator keeps the stored price and TWAP.
        adapter::update_price_feed(&fx.source, config, pfs, &obj);
        let feed = pfs.price_feed(source_id);
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        assert!(price == (65_000 * ONE as u128) && timestamp_ms == 1_700_000_000_000);
        assert!(feed.twap_price() == price);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = agg::EInvalidSourceObjectForFeed)]
fun a_feed_stays_bound_to_its_price_object() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    let other = pyth_object(&mut sc, 7_000_000_000_000, false, 8, 1_700_000_100);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        adapter::update_price_feed(&fx.source, config, pfs, &other);
    });
    price_info::destroy(obj);
    price_info::destroy(other);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = agg::ESourceNotAuthorized)]
fun a_deauthorized_source_cannot_update() {
    let (mut sc, mut fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
    });
    deauthorize_source(&mut sc, &mut fx);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::update_price_feed(&fx.source, config, pfs, &obj);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

// === Feed administration ===

#[test]
fun the_twap_period_can_be_changed_by_the_vendor() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        adapter::set_twap_period_ms<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, 5_000);
        assert!(pfs.price_feed(source_id).twap_period_ms() == 5_000);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

#[test]
fun feeds_are_removed_by_the_vendor_or_forced_by_the_package_admin() {
    let (mut sc, fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        adapter::remove_price_feed<VK>(&fx.source, &fx.oracle_vk, config, pfs);
        assert!(!pfs.contains(source_id) && pfs.size() == 0);
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
        adapter::force_remove_price_feed<ADMIN>(&fx.source, &fx.oracle_admin, config, pfs);
        assert!(!pfs.contains(source_id));
    });
    price_info::destroy(obj);
    finish(sc, fx);
}

#[test]
fun the_source_version_gates_the_adapter() {
    let (mut sc, mut fx) = setup();
    // Bumping the source past the adapter's version locks this adapter out.
    bump_source_version(&mut sc, &mut fx, 2);
    assert!(fx.source.version() == 2);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = oracle_aggregator::source::EInvalidVersion)]
fun a_newer_source_version_refuses_this_adapter() {
    let (mut sc, mut fx) = setup();
    let obj = pyth_object(&mut sc, 6_500_000_000_000, false, 8, 1_700_000_000);
    bump_source_version(&mut sc, &mut fx, 2);
    with_storage!(&mut sc, &fx, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(&fx.source, &fx.oracle_vk, config, pfs, &obj, 60_000);
    });
    price_info::destroy(obj);
    finish(sc, fx);
}
