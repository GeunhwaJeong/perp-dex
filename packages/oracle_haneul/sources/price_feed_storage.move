// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Writes prices signed off chain into `oracle_aggregator` feeds. Anyone may relay a signed
/// update, so a trader can refresh the feeds in the same transaction that trades on them; what
/// is written is decided by the signature, not by who submits it.
module oracle_aggregator_haneul_integration::price_feed_storage;

use authority_cap::authority::{ADMIN, AuthorityCap};
use oracle_aggregator::authority as oracle_authority;
use haneul::bcs;
use haneul::clock::Clock;
use haneul::ed25519;
use oracle_aggregator::{
    authority::{PACKAGE, VENDOR},
    config::Config,
    price_feed_storage::PriceFeedStorage,
    source::Source,
};
use oracle_aggregator_haneul_integration::source::HANEUL;

use fun oracle_aggregator_haneul_integration::source::assert_version as Source.assert_version;
use fun oracle_aggregator_haneul_integration::source::source_cap as Source.source_cap;
use fun oracle_aggregator_haneul_integration::source::signer_expires_at_ms
    as Source.signer_expires_at_ms;
use fun oracle_aggregator_haneul_integration::source::max_confidence_bps
    as Source.max_confidence_bps;
use fun oracle_aggregator_haneul_integration::source::max_future_drift_ms
    as Source.max_future_drift_ms;
use fun oracle_aggregator_haneul_integration::source::step_limit as Source.step_limit;

// === Errors and constants ===

#[error(code = 0)]
const ESignerNotTrusted: vector<u8> =
    b"Signed source: the public key is not in the source's signer set.";
#[error(code = 1)]
const ESignerExpired: vector<u8> = b"Signed source: the signer has expired.";
#[error(code = 2)]
const EInvalidSignature: vector<u8> =
    b"Signed source: the signature does not match the price update.";
#[error(code = 3)]
const EZeroPrice: vector<u8> = b"Signed source: the price must be non-zero.";
#[error(code = 4)]
const ETimestampInFuture: vector<u8> =
    b"Signed source: the update's timestamp is too far ahead of the chain clock.";
#[error(code = 5)]
const EConfidenceTooWide: vector<u8> =
    b"Signed source: the price's confidence interval is wider than the source allows.";
#[error(code = 6)]
const EStepTooLarge: vector<u8> =
    b"Signed source: the price is further from the stored one than the feed's step limit allows.";

const BPS: u256 = 10_000;

/// Separates price updates from anything else the signer's key may sign.
const MESSAGE_DOMAIN: vector<u8> = b"haneul_oracle::PriceUpdate";

// === Types ===

/// What the signer signs, as its BCS bytes. `source` is the `Source<HANEUL>` object, whose id
/// differs between deployments and networks, and `storage_id` the feed, so an update can be
/// replayed neither on another network nor into another asset's feed.
public struct PriceUpdate has copy, drop {
    domain: vector<u8>,
    source: ID,
    storage_id: u32,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
}

// === Functions ===

public fun new_price_feed<VendorKey, ADMIN_OR_ASSISTANT>(
    source: &Source<HANEUL>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
    public_key: vector<u8>,
    signature: vector<u8>,
    twap_period_ms: u64,
    clock: &Clock,
) {
    source.assert_version();
    assert_accepted(
        source,
        price_feed_storage.storage_id(),
        price,
        confidence,
        timestamp_ms,
        &public_key,
        &signature,
        clock,
    );
    price_feed_storage.new_price_feed(
        cap,
        config,
        source.source_cap(),
        source,
        price,
        timestamp_ms,
        twap_period_ms,
    )
}

/// Writes a signed price into the source's feed. An update that is not newer than the stored
/// price is skipped without aborting, so that two relays of the same update, or a relay that
/// lost the race to a newer one, do not fail the transactions they are part of.
public fun update_price_feed(
    source: &Source<HANEUL>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
    public_key: vector<u8>,
    signature: vector<u8>,
    clock: &Clock,
) {
    source.assert_version();
    assert_accepted(
        source,
        price_feed_storage.storage_id(),
        price,
        confidence,
        timestamp_ms,
        &public_key,
        &signature,
        clock,
    );
    assert_step_within_limit(source, price_feed_storage, price, timestamp_ms);
    price_feed_storage.update_price_feed(
        config,
        source.source_cap(),
        source,
        price,
        timestamp_ms,
    )
}

/// Writes a signed price that the feed's step limit would refuse. For the package admin, once
/// it has confirmed that the market really is that far from the stored price: after an outage
/// during a large move no update can pass the limit's maximum. Everything else an update has
/// to satisfy still applies, the signature first of all.
public fun force_update_price_feed<ADMIN_OR_ASSISTANT>(
    source: &Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    price_feed_storage: &mut PriceFeedStorage,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
    public_key: vector<u8>,
    signature: vector<u8>,
    clock: &Clock,
) {
    source.assert_version();
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);
    assert_accepted(
        source,
        price_feed_storage.storage_id(),
        price,
        confidence,
        timestamp_ms,
        &public_key,
        &signature,
        clock,
    );
    price_feed_storage.update_price_feed(
        config,
        source.source_cap(),
        source,
        price,
        timestamp_ms,
    )
}

public fun set_twap_period_ms<VendorKey, ADMIN_OR_MAINTENANCE>(
    source: &Source<HANEUL>,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_MAINTENANCE>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
    twap_period_ms: u64,
) {
    source.assert_version();
    price_feed_storage.set_twap_period_ms(authority_cap, config, source.source_id(), twap_period_ms)
}

public fun remove_price_feed<VendorKey>(
    source: &Source<HANEUL>,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
) {
    source.assert_version();
    price_feed_storage.remove_price_feed(authority_cap, config, source.source_cap())
}

public fun force_remove_price_feed<ADMIN_OR_ASSISTANT>(
    source: &Source<HANEUL>,
    authority_cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    price_feed_storage: &mut PriceFeedStorage,
) {
    source.assert_version();
    price_feed_storage.force_remove_price_feed(authority_cap, config, source.source_id())
}

/// The bytes a signer signs for a price update of the feed `storage_id` through `source`.
public fun price_update_message(
    source: &Source<HANEUL>,
    storage_id: u32,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
): vector<u8> {
    bcs::to_bytes(&PriceUpdate {
        domain: MESSAGE_DOMAIN,
        source: source.object_id(),
        storage_id,
        price,
        confidence,
        timestamp_ms,
    })
}

/// Aborts unless the update is signed by one of the source's live signers and within the
/// source's bounds: a non-zero 18-decimal price, a timestamp no further ahead of the chain
/// clock than the drift bound, and a confidence interval (at the price's scale) no wider than
/// the confidence bound.
fun assert_accepted(
    source: &Source<HANEUL>,
    storage_id: u32,
    price: u128,
    confidence: u128,
    timestamp_ms: u64,
    public_key: &vector<u8>,
    signature: &vector<u8>,
    clock: &Clock,
) {
    let now_ms = clock.timestamp_ms();

    let expires_at_ms = source.signer_expires_at_ms(public_key);
    assert!(expires_at_ms.is_some(), ESignerNotTrusted);
    assert!(now_ms < expires_at_ms.destroy_some(), ESignerExpired);

    let message = price_update_message(source, storage_id, price, confidence, timestamp_ms);
    assert!(ed25519::ed25519_verify(signature, public_key, &message), EInvalidSignature);

    assert!(price != 0, EZeroPrice);
    assert!(
        (timestamp_ms as u128) <= (now_ms as u128) + (source.max_future_drift_ms() as u128),
        ETimestampInFuture,
    );
    assert!(
        (confidence as u256) * BPS <= (price as u256) * (source.max_confidence_bps() as u256),
        EConfidenceTooWide,
    );
}

/// Aborts if the update is newer than the stored price and further from it than the feed's
/// step limit allows for the time between the two. An update that is not newer is not checked:
/// the feed skips it, and a late relay must not fail the transaction it is part of.
fun assert_step_within_limit(
    source: &Source<HANEUL>,
    price_feed_storage: &PriceFeedStorage,
    price: u128,
    timestamp_ms: u64,
) {
    let (stored_price, stored_timestamp_ms) = price_feed_storage
        .price_feed(source.source_id())
        .price_and_timestamp_ms();
    if (timestamp_ms <= stored_timestamp_ms) return;
    let limit = source.step_limit(price_feed_storage.storage_id());
    assert!(
        limit.allows(stored_price, price, timestamp_ms - stored_timestamp_ms),
        EStepTooLarge,
    );
}
