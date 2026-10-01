// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for the signed-price source: which updates it accepts, what it writes into the
/// aggregator's feeds, and who may change its signer set and bounds.
///
/// Move cannot sign, so the updates are signed ahead of time by `e2e/oracle_signing.py` with
/// two throwaway keys. A signature covers the id of the `Source<HANEUL>` object, which the test
/// scenario derives deterministically; `the_fixture_signatures_are_for_this_source` fails first
/// if the setup ever changes that id, and says how to regenerate the constants below.
#[test_only]
module oracle_aggregator_haneul_integration::signed_source_tests;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::clock::{Self, Clock};
use haneul::test_scenario::{Self as ts, Scenario};
use oracle_aggregator::config::Config as OracleConfig;
use oracle_aggregator::init as oracle_init;
use oracle_aggregator::price_feed_storage::{Self as agg, PriceFeedStorage};
use oracle_aggregator::source::Source;
use oracle_aggregator_haneul_integration::price_feed_storage as adapter;
use oracle_aggregator_haneul_integration::source::{Self as signed_source, HANEUL};
use vendor::config::{Self as vendor_config, Config as VendorConfig};
use vendor::init as vendor_init;
use std::unit_test::assert_eq;
use vendor::metadata::{Self, VendorMetadata};

const ONE: u128 = 1_000_000_000_000_000_000;
const TWAP_PERIOD_MS: u64 = 60_000;
const NEVER: u64 = 18_446_744_073_709_551_615;

// === Signed updates (python3 e2e/oracle_signing.py fixtures <FIXTURE_SOURCE>) ===

const FIXTURE_SOURCE: address = @0x9ae707b98dfe186ddf62cbdaf35e030c4bcb1f74985af871b581098030e2cf82;

const SIGNER: vector<u8> = x"d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737";
const OTHER_SIGNER: vector<u8> = x"a09aa5f47a6759802ff955f8dc2d2a14a5c99d23be97f864127ff9383455a4f0";
/// Feed 0: 68,000 +/- 10 at 1,000,000 ms.
const SIG_FIRST: vector<u8> = x"e9f2944160398b2b899b6131f323f024b5d59634dd196aba700371523c96cc5d8c3c45f8b72273e144ed87dff82fae15a85c9acf5517e3f5aaba9fffd2fb1201";
/// Feed 0: 68,500 +/- 10 at 1,005,000 ms.
const SIG_SECOND: vector<u8> = x"3bb2a73d87c6e7f0d37ec5c526471818877f9706f1660729aa9313fab643f6d7e186be5af8936463fd9bbba8af0ce2fa93023a0edb583dff10eb32568a7ca206";
/// Feed 0: 68,000 +/- 1,360 (2%) at 1,010,000 ms.
const SIG_WIDE: vector<u8> = x"4fa274ee03b9e5857190ca85d721fb4ed5f74182533f9641b31611678f0bf10171a96ee9b3b950bf7609b4667069020c3d1598f1ee6ce6e08e066fdde1470401";
/// Feed 0: 68,000 +/- 680 (1%) at 1,010,000 ms.
const SIG_AT_BOUND: vector<u8> = x"fd1e358fa81f7d33de9d8c4cf19ed1e59951823e12c3385246c5c0b649ccda179358ff3b7af56fbef395f370b259425dc967f603776d4bbf10e25ea2642bf00f";
/// Feed 0: a zero price at 1,010,000 ms.
const SIG_ZERO: vector<u8> = x"95b58fabc0c0d31e733bba64cc01e8db4c30ac0f806d5a3f61ec3c24e6da8aa40b5e7a9a88e7457ed2a8d3d8d427133786b8fdbd71b73f272ae9db32f5bf0709";
/// Feed 0: 68,000 +/- 10 at 1,013,000 ms.
const SIG_AHEAD: vector<u8> = x"493ec7aed62c246cc0da18e1f147f02c0bbb4020c44f3eceadd984e560c4d03a0aaecc26d502ec73ab0afd45ddd0e0b554d1c601c7549f95ca1135ec5c89340a";
/// Feed 0: 68,000 +/- 10 at 1,013,001 ms.
const SIG_TOO_FAR_AHEAD: vector<u8> = x"e4ecc40fa382e11d324b98738aa96a2d63353a6a022dcee50a2435ed4ba025a4c76fb86cd38965c261629c1b074f1b7e0c98129ee1234a872dfeb6f7abf8210a";
/// Feed 1: 2,000 +/- 1 at 1,000,000 ms.
const SIG_OTHER_FEED: vector<u8> = x"9d48e4adb6d91bf9171b2f8c7ff8ae22b55a8a93f6537146b2d478a580297479209a9ab4f084ede820645037b5b5db63a2e416b78ae76597c87e7837db43c30c";
/// Feed 0: 68,500 +/- 10 at 1,005,000 ms, signed by `OTHER_SIGNER`.
const SIG_OTHER_SIGNER: vector<u8> = x"a20e7a0b74f33394d664789df422886017f9c3f41c7ed9fba416c602c730404a0c9fecdbdbfd579e4b62e6de1447b70a543c9355cc901bb794ea79e71f31f806";

public struct VK has drop {}

// === Fixture ===

public struct Fx {
    admin: address,
    vendor_cap: AuthorityCap<vendor::authority::VENDOR<VK>, ADMIN>,
    oracle_admin: AuthorityCap<oracle_aggregator::authority::PACKAGE, ADMIN>,
    oracle_vk: AuthorityCap<oracle_aggregator::authority::VENDOR<VK>, ADMIN>,
    metadata: VendorMetadata<VK>,
    source: Source<HANEUL>,
    clock: Clock,
    /// Feed 0.
    btc: ID,
    /// Feed 1.
    eth: ID,
}

/// An authorized source with `SIGNER` in its signer set and two empty storages, at 1,000,000 ms.
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
        &mut vconfig, &vendor_cap, b"Signed source tests".to_ascii_string(), b"".to_ascii_string(),
    );
    md.approve_domain_registration<VK, oracle_aggregator::authority::PACKAGE>(&vconfig, &oracle_admin);
    let oracle_vk = oconfig.register_vendor<VK, ADMIN>(&vendor_cap, &vconfig, &md);

    let mut clock = clock::create_for_testing(sc.ctx());
    clock.set_for_testing(1_000_000);
    let mut source = signed_source::create<ADMIN>(&mut oconfig, &oracle_admin);
    signed_source::authorize(&mut source, &oconfig, &oracle_admin);
    signed_source::set_signer(&mut source, &oconfig, &oracle_admin, SIGNER, NEVER, &clock);

    let btc = agg::new<VK, ADMIN>(&mut oconfig, &oracle_vk, b"BTC/USD".to_string());
    let eth = agg::new<VK, ADMIN>(&mut oconfig, &oracle_vk, b"ETH/USD".to_string());
    let (btc_id, eth_id) = (object::id(&btc), object::id(&eth));
    transfer::public_share_object(btc);
    transfer::public_share_object(eth);
    ts::return_shared(vconfig);
    ts::return_shared(oconfig);
    sc.return_to_sender(vendor_pkg_admin);
    (
        sc,
        Fx {
            admin,
            vendor_cap,
            oracle_admin,
            oracle_vk,
            metadata: md,
            source,
            clock,
            btc: btc_id,
            eth: eth_id,
        },
    )
}

fun finish(sc: Scenario, fx: Fx) {
    let Fx { admin: _, vendor_cap, oracle_admin, oracle_vk, metadata, source, clock, btc: _, eth: _ } = fx;
    transfer::public_transfer(vendor_cap, @0x0);
    transfer::public_transfer(oracle_admin, @0x0);
    transfer::public_transfer(oracle_vk, @0x0);
    transfer::public_transfer(metadata, @0x0);
    transfer::public_transfer(source, @0x0);
    clock.destroy_for_testing();
    sc.end();
}

/// Runs `$f` with the oracle config and the storage `$pfs`.
macro fun with_storage(
    $sc: &mut Scenario,
    $fx: &Fx,
    $pfs: ID,
    $f: |&OracleConfig, &mut PriceFeedStorage|,
) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin);
    let oconfig = sc.take_shared<OracleConfig>();
    let mut pfs = sc.take_shared_by_id<PriceFeedStorage>($pfs);
    $f(&oconfig, &mut pfs);
    ts::return_shared(oconfig);
    ts::return_shared(pfs);
}

/// Runs `$f` with the oracle config and the fixture, for calls that change the source.
macro fun with_config($sc: &mut Scenario, $fx: &mut Fx, $f: |&OracleConfig, &mut Fx|) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin);
    let oconfig = sc.take_shared<OracleConfig>();
    $f(&oconfig, fx);
    ts::return_shared(oconfig);
}

/// Creates feed 0 from the first signed update: 68,000 at 1,000,000 ms.
fun create_btc_feed(sc: &mut Scenario, fx: &Fx) {
    with_storage!(sc, fx, fx.btc, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(
            &fx.source, &fx.oracle_vk, config, pfs,
            68_000 * ONE, 10 * ONE, 1_000_000, SIGNER, SIG_FIRST, TWAP_PERIOD_MS, &fx.clock,
        );
    });
}

/// Relays an update of feed 0 signed by `SIGNER`.
fun update_btc(
    sc: &mut Scenario,
    fx: &Fx,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
    signature: vector<u8>,
) {
    with_storage!(sc, fx, fx.btc, |config, pfs| {
        adapter::update_price_feed(
            &fx.source, config, pfs, price, confidence, timestamp_ms, SIGNER, signature, &fx.clock,
        );
    });
}

fun btc_price_and_timestamp_ms(sc: &mut Scenario, fx: &Fx): (u128, u64) {
    let source_id = fx.source.source_id();
    let (mut price, mut timestamp_ms) = (0, 0);
    with_storage!(sc, fx, fx.btc, |_, pfs| {
        (price, timestamp_ms) = pfs.price_feed(source_id).price_and_timestamp_ms();
    });
    (price, timestamp_ms)
}

// === Fixture consistency ===

#[test]
fun the_fixture_signatures_are_for_this_source() {
    let (sc, fx) = setup();
    // If this fails the setup now derives another source id, which the failure prints:
    // regenerate the constants with `python3 e2e/oracle_signing.py fixtures <that id>`.
    assert_eq!(fx.source.object_id().to_address(), FIXTURE_SOURCE);
    finish(sc, fx);
}

#[test]
fun the_signed_message_is_the_bcs_of_the_update() {
    let (sc, fx) = setup();
    let message = adapter::price_update_message(&fx.source, 7, 68_000 * ONE, 10 * ONE, 1_000_000);
    let mut expected = vector[26u8];
    expected.append(b"haneul_oracle::PriceUpdate");
    expected.append(FIXTURE_SOURCE.to_bytes());
    // storage_id as a little-endian u32.
    expected.append(x"07000000");
    // 68,000e18 and 10e18 as little-endian u128, then 1,000,000 as a little-endian u64.
    expected.append(x"000080228f289249660e000000000000");
    expected.append(x"0000e8890423c78a0000000000000000");
    expected.append(x"40420f0000000000");
    assert!(message == expected);
    finish(sc, fx);
}

// === Feed creation and updates ===

#[test]
fun new_price_feed_stores_the_signed_price_and_timestamp() {
    let (mut sc, fx) = setup();
    create_btc_feed(&mut sc, &fx);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, fx.btc, |_, pfs| {
        assert!(pfs.contains(source_id) && pfs.size() == 1);
        let feed = pfs.price_feed(source_id);
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        assert!(price == 68_000 * ONE && timestamp_ms == 1_000_000);
        assert!(feed.twap_price() == price && feed.twap_period_ms() == TWAP_PERIOD_MS);
        assert!(feed.from() == fx.source.object_id());
    });
    finish(sc, fx);
}

#[test]
fun a_newer_signed_price_replaces_the_stored_one() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, fx.btc, |_, pfs| {
        let feed = pfs.price_feed(source_id);
        let (price, timestamp_ms) = feed.price_and_timestamp_ms();
        assert!(price == 68_500 * ONE && timestamp_ms == 1_005_000);
        // 5 s of the 60 s window at the new price: 68,000 + 500 * 5 / 60.
        assert!(feed.twap_price() == (68_000 * ONE * 55 + 68_500 * ONE * 5) / 60);
    });
    finish(sc, fx);
}

#[test]
fun an_update_that_is_not_newer_is_skipped_without_aborting() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    // The same update relayed twice, then the older one relayed late.
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    update_btc(&mut sc, &fx, 68_000 * ONE, 10 * ONE, 1_000_000, SIG_FIRST);
    let (price, timestamp_ms) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(price == 68_500 * ONE && timestamp_ms == 1_005_000);
    finish(sc, fx);
}

#[test]
fun each_feed_takes_only_updates_signed_for_it() {
    let (mut sc, fx) = setup();
    create_btc_feed(&mut sc, &fx);
    let source_id = fx.source.source_id();
    with_storage!(&mut sc, &fx, fx.eth, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(
            &fx.source, &fx.oracle_vk, config, pfs,
            2_000 * ONE, ONE, 1_000_000, SIGNER, SIG_OTHER_FEED, TWAP_PERIOD_MS, &fx.clock,
        );
        let (price, _) = pfs.price_feed(source_id).price_and_timestamp_ms();
        assert!(price == 2_000 * ONE);
    });
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun an_update_signed_for_another_feed_is_refused() {
    let (mut sc, fx) = setup();
    with_storage!(&mut sc, &fx, fx.btc, |config, pfs| {
        adapter::new_price_feed<VK, ADMIN>(
            &fx.source, &fx.oracle_vk, config, pfs,
            2_000 * ONE, ONE, 1_000_000, SIGNER, SIG_OTHER_FEED, TWAP_PERIOD_MS, &fx.clock,
        );
    });
    finish(sc, fx);
}

#[test, expected_failure(abort_code = agg::ESourceNotAuthorized)]
fun a_deauthorized_source_cannot_write() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::deauthorize(&mut fx.source, config, &fx.oracle_admin);
    });
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    finish(sc, fx);
}

// === Signatures ===

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun a_changed_price_invalidates_the_signature() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE + 1, 10 * ONE, 1_005_000, SIG_SECOND);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun a_changed_confidence_invalidates_the_signature() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 9 * ONE, 1_005_000, SIG_SECOND);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun a_changed_timestamp_invalidates_the_signature() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    // Restamping an old signed price to keep it fresh.
    update_btc(&mut sc, &fx, 68_000 * ONE, 10 * ONE, 1_005_000, SIG_FIRST);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun a_signature_by_another_key_does_not_pass_as_the_signers() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_OTHER_SIGNER);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EInvalidSignature)]
fun a_malformed_signature_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, x"00");
    finish(sc, fx);
}

// === Signer set ===

#[test, expected_failure(abort_code = adapter::ESignerNotTrusted)]
fun a_key_outside_the_signer_set_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_005_000);
    with_storage!(&mut sc, &fx, fx.btc, |config, pfs| {
        adapter::update_price_feed(
            &fx.source, config, pfs,
            68_500 * ONE, 10 * ONE, 1_005_000, OTHER_SIGNER, SIG_OTHER_SIGNER, &fx.clock,
        );
    });
    finish(sc, fx);
}

#[test]
fun a_second_signer_is_accepted_once_added() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_signer(
            &mut fx.source, config, &fx.oracle_admin, OTHER_SIGNER, 2_000_000, &fx.clock,
        );
    });
    assert!(signed_source::signers(&fx.source) == vector[SIGNER, OTHER_SIGNER]);
    let other_signer = OTHER_SIGNER;
    assert!(signed_source::signer_expires_at_ms(&fx.source, &other_signer) == option::some(2_000_000));
    fx.clock.set_for_testing(1_005_000);
    with_storage!(&mut sc, &fx, fx.btc, |config, pfs| {
        adapter::update_price_feed(
            &fx.source, config, pfs,
            68_500 * ONE, 10 * ONE, 1_005_000, OTHER_SIGNER, SIG_OTHER_SIGNER, &fx.clock,
        );
    });
    let (price, _) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(price == 68_500 * ONE);
    finish(sc, fx);
}

#[test]
fun a_signer_is_accepted_until_the_millisecond_before_it_expires() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        // Moves the expiry of the signer already in the set.
        signed_source::set_signer(
            &mut fx.source, config, &fx.oracle_admin, SIGNER, 1_005_001, &fx.clock,
        );
    });
    assert!(signed_source::signers(&fx.source) == vector[SIGNER]);
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    let (price, _) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(price == 68_500 * ONE);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::ESignerExpired)]
fun an_expired_signer_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_signer(
            &mut fx.source, config, &fx.oracle_admin, SIGNER, 1_005_000, &fx.clock,
        );
    });
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::ESignerNotTrusted)]
fun a_removed_signer_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::remove_signer(&mut fx.source, config, &fx.oracle_admin, SIGNER);
    });
    assert!(signed_source::signers(&fx.source).is_empty());
    let signer = SIGNER;
    assert!(signed_source::signer_expires_at_ms(&fx.source, &signer).is_none());
    fx.clock.set_for_testing(1_005_000);
    update_btc(&mut sc, &fx, 68_500 * ONE, 10 * ONE, 1_005_000, SIG_SECOND);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::ESignerNotFound)]
fun removing_an_unknown_signer_aborts() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::remove_signer(&mut fx.source, config, &fx.oracle_admin, OTHER_SIGNER);
    });
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::EInvalidPublicKeyLength)]
fun a_signer_key_must_be_32_bytes() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_signer(
            &mut fx.source, config, &fx.oracle_admin, x"0102", NEVER, &fx.clock,
        );
    });
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::ESignerAlreadyExpired)]
fun a_signer_cannot_be_set_with_a_past_expiry() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_signer(
            &mut fx.source, config, &fx.oracle_admin, OTHER_SIGNER, 1_000_000, &fx.clock,
        );
    });
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::ETooManySigners)]
fun the_signer_set_holds_at_most_sixteen_keys() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        // `SIGNER` is the first; fifteen more fill the set and the next one is refused.
        let mut i = 1u8;
        while (i <= 16) {
            let mut key = vector[i];
            while (key.length() < 32) key.push_back(0);
            signed_source::set_signer(&mut fx.source, config, &fx.oracle_admin, key, NEVER, &fx.clock);
            i = i + 1;
        };
    });
    finish(sc, fx);
}

// === Bounds ===

#[test, expected_failure(abort_code = adapter::EZeroPrice)]
fun a_signed_zero_price_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_010_000);
    update_btc(&mut sc, &fx, 0, 0, 1_010_000, SIG_ZERO);
    finish(sc, fx);
}

#[test]
fun a_confidence_interval_at_the_bound_is_accepted() {
    let (mut sc, mut fx) = setup();
    assert!(signed_source::max_confidence_bps(&fx.source) == 100);
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_010_000);
    // Exactly 1% of 68,000: the default bound is inclusive.
    update_btc(&mut sc, &fx, 68_000 * ONE, 680 * ONE, 1_010_000, SIG_AT_BOUND);
    let (_, timestamp_ms) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(timestamp_ms == 1_010_000);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::EConfidenceTooWide)]
fun a_wide_confidence_interval_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_010_000);
    update_btc(&mut sc, &fx, 68_000 * ONE, 1_360 * ONE, 1_010_000, SIG_WIDE);
    finish(sc, fx);
}

#[test]
fun a_raised_confidence_bound_admits_the_wide_interval() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_max_confidence_bps(&mut fx.source, config, &fx.oracle_admin, 200);
    });
    assert!(signed_source::max_confidence_bps(&fx.source) == 200);
    fx.clock.set_for_testing(1_010_000);
    update_btc(&mut sc, &fx, 68_000 * ONE, 1_360 * ONE, 1_010_000, SIG_WIDE);
    let (_, timestamp_ms) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(timestamp_ms == 1_010_000);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::EInvalidConfidenceBound)]
fun the_confidence_bound_is_at_most_the_whole_price() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_max_confidence_bps(&mut fx.source, config, &fx.oracle_admin, 10_001);
    });
    finish(sc, fx);
}

#[test]
fun a_timestamp_ahead_of_the_clock_by_the_drift_bound_is_accepted() {
    let (mut sc, mut fx) = setup();
    assert!(signed_source::max_future_drift_ms(&fx.source) == 3_000);
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_010_000);
    update_btc(&mut sc, &fx, 68_000 * ONE, 10 * ONE, 1_013_000, SIG_AHEAD);
    let (_, timestamp_ms) = btc_price_and_timestamp_ms(&mut sc, &fx);
    assert!(timestamp_ms == 1_013_000);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::ETimestampInFuture)]
fun a_timestamp_beyond_the_drift_bound_is_refused() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    fx.clock.set_for_testing(1_010_000);
    update_btc(&mut sc, &fx, 68_000 * ONE, 10 * ONE, 1_013_001, SIG_TOO_FAR_AHEAD);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = adapter::ETimestampInFuture)]
fun a_zero_drift_bound_refuses_any_timestamp_ahead_of_the_clock() {
    let (mut sc, mut fx) = setup();
    create_btc_feed(&mut sc, &fx);
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_max_future_drift_ms(&mut fx.source, config, &fx.oracle_admin, 0);
    });
    fx.clock.set_for_testing(1_012_999);
    update_btc(&mut sc, &fx, 68_000 * ONE, 10 * ONE, 1_013_000, SIG_AHEAD);
    finish(sc, fx);
}

#[test, expected_failure(abort_code = signed_source::EInvalidFutureDrift)]
fun the_drift_bound_is_at_most_a_minute() {
    let (mut sc, mut fx) = setup();
    with_config!(&mut sc, &mut fx, |config, fx| {
        signed_source::set_max_future_drift_ms(&mut fx.source, config, &fx.oracle_admin, 60_001);
    });
    finish(sc, fx);
}

// === Authority ===

#[test, expected_failure(abort_code = oracle_aggregator::config::EInactiveAuthorityCap)]
fun a_revoked_assistant_cap_cannot_change_the_signer_set() {
    let (mut sc, mut fx) = setup();
    sc.next_tx(fx.admin);
    let mut oconfig = sc.take_shared<OracleConfig>();
    let assistant = oconfig.new_package_assistant_cap(&fx.oracle_admin, sc.ctx());
    let Fx { source, oracle_admin, clock, .. } = &mut fx;
    signed_source::set_max_confidence_bps(source, &oconfig, &assistant, 50);
    assert!(signed_source::max_confidence_bps(source) == 50);
    oconfig.revoke_package_assistant_cap(oracle_admin, object::id(&assistant));
    signed_source::set_signer(source, &oconfig, &assistant, OTHER_SIGNER, NEVER, clock);
    transfer::public_transfer(assistant, @0x0);
    ts::return_shared(oconfig);
    finish(sc, fx);
}
