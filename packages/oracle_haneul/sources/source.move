// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The signed-price source: its registration with the aggregator, the set of signers whose
/// price updates it accepts, and the bounds an update has to stay within.
///
/// The step limit bounds how far one update may move a feed's price: `base_bps` at once plus
/// `bps_per_second` for every second since the stored price, up to `max_bps`. It is a net under
/// the signer, not a smoother. A decimal slip, a mis-mapped market or a stolen key shows up as
/// a price that jumps, and such an update is refused, which leaves the feed stale and stops
/// the markets. The limit is meant to be wide enough that a real crash passes: an oracle that
/// trails the market is itself something to trade against. Because the allowance grows with
/// the time since the stored price, a relayer that missed a few rounds is not locked out, and
/// only a gap beyond `max_bps` needs the package admin (`force_update_price_feed`).
module oracle_aggregator_haneul_integration::source;

use authority_cap::authority::AuthorityCap;
use haneul::clock::Clock;
use haneul::dynamic_field;
use haneul::vec_map::{Self, VecMap};
use oracle_aggregator::{
    authority::{Self as oracle_authority, PACKAGE, SourceCap},
    config::Config,
    source::{Self as aggregator_source, Source},
};
use oracle_aggregator_haneul_integration::events;

// === Errors and constants ===

#[error(code = 0)]
const EInvalidPublicKeyLength: vector<u8> =
    b"Signed source: an Ed25519 public key is 32 bytes long.";
#[error(code = 1)]
const ESignerAlreadyExpired: vector<u8> =
    b"Signed source: the signer's expiry has to lie in the future.";
#[error(code = 2)]
const ESignerNotFound: vector<u8> = b"Signed source: no signer with this public key.";
#[error(code = 3)]
const ETooManySigners: vector<u8> = b"Signed source: the signer set is full.";
#[error(code = 4)]
const EInvalidConfidenceBound: vector<u8> =
    b"Signed source: the confidence bound is in basis points of the price, at most 10,000.";
#[error(code = 5)]
const EInvalidFutureDrift: vector<u8> =
    b"Signed source: the future drift bound is at most one minute.";
#[error(code = 6)]
const EInvalidStepLimit: vector<u8> =
    b"Signed source: step limits are in basis points, at most 10,000, with the base within the maximum.";
#[error(code = 7)]
const EStepLimitNotFound: vector<u8> = b"Signed source: the feed has no step limit of its own.";

const CURRENT_VERSION: u64 = 1;

const ED25519_PUBLIC_KEY_LENGTH: u64 = 32;
const MAX_SIGNERS: u64 = 16;
const BPS: u64 = 10_000;

/// Widest confidence interval accepted until the package admin sets one: 1% of the price.
const DEFAULT_MAX_CONFIDENCE_BPS: u64 = 100;
/// How far ahead of the chain clock an update's timestamp may be. The signer stamps updates
/// with its wall clock, which runs slightly ahead of the consensus timestamp the chain exposes.
const DEFAULT_MAX_FUTURE_DRIFT_MS: u64 = 3_000;
/// A larger drift would let a signed price outlive the markets' own staleness tolerance.
const MAX_FUTURE_DRIFT_MS: u64 = 60_000;
/// Step limit of a feed that has none of its own: 0.5% at once plus 0.5% per second, which is
/// 2% for an update every three seconds and 40% over a minute, and 20% at most.
const DEFAULT_STEP_BASE_BPS: u64 = 50;
const DEFAULT_STEP_BPS_PER_SECOND: u64 = 50;
const DEFAULT_STEP_MAX_BPS: u64 = 2_000;

// === Types ===

public struct HANEUL has drop {}

/// Key of the `Settings` kept on the `Source<HANEUL>` object.
public struct SettingsKey has copy, drop, store {}

public struct Settings has store {
    /// Ed25519 public key to the millisecond timestamp its signatures stop being accepted at.
    signers: VecMap<vector<u8>, u64>,
    max_confidence_bps: u64,
    max_future_drift_ms: u64,
    /// Step limit of the feeds that have none of their own.
    default_step_limit: StepLimit,
}

/// How far an update may move a feed's price from the stored one, in basis points of the
/// stored price: `base_bps + bps_per_second * seconds since the stored price`, at most
/// `max_bps`. All zeros pin the feed to its stored price.
public struct StepLimit has copy, drop, store {
    base_bps: u64,
    bps_per_second: u64,
    max_bps: u64,
}

/// Key of a feed's own `StepLimit` on the `Source<HANEUL>` object, by the feed's storage id.
public struct StepLimitKey has copy, drop, store(u32)

// === Functions ===

public fun create<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
): Source<HANEUL> {
    let mut source = aggregator_source::create(config, cap, &HANEUL {}, CURRENT_VERSION);
    dynamic_field::add(
        source.borrow_mut_id(HANEUL {}),
        SettingsKey {},
        Settings {
            signers: vec_map::empty(),
            max_confidence_bps: DEFAULT_MAX_CONFIDENCE_BPS,
            max_future_drift_ms: DEFAULT_MAX_FUTURE_DRIFT_MS,
            default_step_limit: StepLimit {
                base_bps: DEFAULT_STEP_BASE_BPS,
                bps_per_second: DEFAULT_STEP_BPS_PER_SECOND,
                max_bps: DEFAULT_STEP_MAX_BPS,
            },
        },
    );
    source
}

public fun authorize<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert_version(source);
    source.set_authorized(config, cap, true)
}

public fun deauthorize<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert_version(source);
    source.set_authorized(config, cap, false)
}

/// Adds a signer, or moves the expiry of one already in the set.
public fun set_signer<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    public_key: vector<u8>,
    expires_at_ms: u64,
    clock: &Clock,
) {
    assert_package_admin_or_assistant(source, config, cap);
    assert!(public_key.length() == ED25519_PUBLIC_KEY_LENGTH, EInvalidPublicKeyLength);
    assert!(expires_at_ms > clock.timestamp_ms(), ESignerAlreadyExpired);

    let source_id = source.source_id();
    let signers = &mut settings_mut(source).signers;
    if (signers.contains(&public_key)) {
        *signers.get_mut(&public_key) = expires_at_ms
    } else {
        assert!(signers.length() < MAX_SIGNERS, ETooManySigners);
        signers.insert(public_key, expires_at_ms)
    };
    events::set_signer(source_id, public_key, expires_at_ms)
}

public fun remove_signer<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    public_key: vector<u8>,
) {
    assert_package_admin_or_assistant(source, config, cap);

    let source_id = source.source_id();
    let signers = &mut settings_mut(source).signers;
    assert!(signers.contains(&public_key), ESignerNotFound);
    signers.remove(&public_key);
    events::removed_signer(source_id, public_key)
}

/// Sets the widest confidence interval the source accepts, in basis points of the price. A
/// price whose interval is wider is refused rather than written, leaving the feed stale so that
/// markets stop on `EBadIndexPrice` instead of trading on an uncertain price.
public fun set_max_confidence_bps<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_confidence_bps: u64,
) {
    assert_package_admin_or_assistant(source, config, cap);
    assert!(max_confidence_bps <= BPS, EInvalidConfidenceBound);

    let source_id = source.source_id();
    let settings = settings_mut(source);
    let old_max_confidence_bps = settings.max_confidence_bps;
    settings.max_confidence_bps = max_confidence_bps;
    events::set_max_confidence_bps(source_id, old_max_confidence_bps, max_confidence_bps)
}

public fun set_max_future_drift_ms<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_future_drift_ms: u64,
) {
    assert_package_admin_or_assistant(source, config, cap);
    assert!(max_future_drift_ms <= MAX_FUTURE_DRIFT_MS, EInvalidFutureDrift);

    let source_id = source.source_id();
    let settings = settings_mut(source);
    let old_max_future_drift_ms = settings.max_future_drift_ms;
    settings.max_future_drift_ms = max_future_drift_ms;
    events::set_max_future_drift_ms(source_id, old_max_future_drift_ms, max_future_drift_ms)
}

/// Sets the step limit of the feeds that have none of their own.
public fun set_default_step_limit<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    base_bps: u64,
    bps_per_second: u64,
    max_bps: u64,
) {
    assert_package_admin_or_assistant(source, config, cap);
    let limit = new_step_limit(base_bps, bps_per_second, max_bps);

    let source_id = source.source_id();
    settings_mut(source).default_step_limit = limit;
    events::set_step_limit(source_id, option::none(), base_bps, bps_per_second, max_bps)
}

/// Sets the step limit of one feed, by the storage id of its `PriceFeedStorage`. A collateral
/// that is worth its quote by construction is pinned with all zeros.
public fun set_step_limit<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    storage_id: u32,
    base_bps: u64,
    bps_per_second: u64,
    max_bps: u64,
) {
    assert_package_admin_or_assistant(source, config, cap);
    let limit = new_step_limit(base_bps, bps_per_second, max_bps);

    let source_id = source.source_id();
    let id = source.borrow_mut_id(HANEUL {});
    let key = StepLimitKey(storage_id);
    if (dynamic_field::exists(id, key)) {
        *dynamic_field::borrow_mut(id, key) = limit
    } else {
        dynamic_field::add(id, key, limit)
    };
    events::set_step_limit(source_id, option::some(storage_id), base_bps, bps_per_second, max_bps)
}

/// Removes a feed's own step limit; the default applies to it again.
public fun remove_step_limit<ADMIN_OR_ASSISTANT>(
    source: &mut Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    storage_id: u32,
) {
    assert_package_admin_or_assistant(source, config, cap);

    let source_id = source.source_id();
    let id = source.borrow_mut_id(HANEUL {});
    let key = StepLimitKey(storage_id);
    assert!(dynamic_field::exists(id, key), EStepLimitNotFound);
    let _: StepLimit = dynamic_field::remove(id, key);
    events::removed_step_limit(source_id, storage_id)
}

/// The timestamp the signer's signatures stop being accepted at, if it is in the set.
public fun signer_expires_at_ms(source: &Source<HANEUL>, public_key: &vector<u8>): Option<u64> {
    settings(source).signers.try_get(public_key)
}

public fun signers(source: &Source<HANEUL>): vector<vector<u8>> {
    settings(source).signers.keys()
}

/// The source's confidence bound in basis points of the price.
public fun max_confidence_bps(source: &Source<HANEUL>): u64 {
    settings(source).max_confidence_bps
}

public fun max_future_drift_ms(source: &Source<HANEUL>): u64 {
    settings(source).max_future_drift_ms
}

/// The step limit that applies to a feed: its own, or the default.
public fun step_limit(source: &Source<HANEUL>, storage_id: u32): StepLimit {
    let id = source.borrow_id();
    let key = StepLimitKey(storage_id);
    if (dynamic_field::exists(id, key)) {
        *dynamic_field::borrow(id, key)
    } else {
        settings(source).default_step_limit
    }
}

public fun default_step_limit(source: &Source<HANEUL>): StepLimit {
    settings(source).default_step_limit
}

public fun has_own_step_limit(source: &Source<HANEUL>, storage_id: u32): bool {
    dynamic_field::exists(source.borrow_id(), StepLimitKey(storage_id))
}

public fun base_bps(limit: &StepLimit): u64 {
    limit.base_bps
}

public fun bps_per_second(limit: &StepLimit): u64 {
    limit.bps_per_second
}

public fun max_bps(limit: &StepLimit): u64 {
    limit.max_bps
}

/// Whether moving a price from `stored` to `price` over `elapsed_ms` is within the limit. The
/// allowance is kept in thousandths of a basis point so that it grows with every millisecond.
public fun allows(limit: &StepLimit, stored: u128, price: u128, elapsed_ms: u64): bool {
    let grown = (limit.base_bps as u256) * 1_000
        + (limit.bps_per_second as u256) * (elapsed_ms as u256);
    let allowance = grown.min((limit.max_bps as u256) * 1_000);
    let step = (price.max(stored) - price.min(stored)) as u256;
    step * (BPS as u256) * 1_000 <= (stored as u256) * allowance
}

fun new_step_limit(base_bps: u64, bps_per_second: u64, max_bps: u64): StepLimit {
    assert!(
        max_bps <= BPS && bps_per_second <= BPS && base_bps <= max_bps,
        EInvalidStepLimit,
    );
    StepLimit { base_bps, bps_per_second, max_bps }
}

public(package) fun source_cap(source: &Source<HANEUL>): &SourceCap {
    source.borrow_source_cap(HANEUL {})
}

public(package) fun assert_version(source: &Source<HANEUL>) {
    aggregator_source::assert_version(source, CURRENT_VERSION)
}

fun assert_package_admin_or_assistant<ADMIN_OR_ASSISTANT>(
    source: &Source<HANEUL>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert_version(source);
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap)
}

fun settings(source: &Source<HANEUL>): &Settings {
    dynamic_field::borrow(source.borrow_id(), SettingsKey {})
}

fun settings_mut(source: &mut Source<HANEUL>): &mut Settings {
    dynamic_field::borrow_mut(source.borrow_mut_id(HANEUL {}), SettingsKey {})
}
