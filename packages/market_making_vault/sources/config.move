// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::config;

use authority_cap::authority::{Self as cap_authority, ADMIN, ASSISTANT, AuthorityCap};
use haneul::bag::{Self, Bag};
use haneul::dynamic_field;
use haneul::types;
use market_making_vault::authority::{Self, FREEZE_GUARDIAN, MAINTENANCE, PACKAGE, PAUSE_GUARDIAN};
use market_making_vault::events;
use market_making_vault::keys;
use std::type_name;
use std::u64;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EConfigAlreadyCreated: vector<u8> = b"The package config has already been created.";
#[error(code = 1)]
const EInvalidVersion: vector<u8> =
    b"This package version cannot be used for the requested action.";
#[error(code = 2)]
const EInvalidAuthorityCap: vector<u8> =
    b"The provided AuthorityCap does not have permission to manage this package.";
#[error(code = 3)]
const EInvalidConfigValue: vector<u8> =
    b"The provided config value would violate package configuration invariants.";
#[error(code = 4)]
const EVaultRecordAlreadyRegistered: vector<u8> =
    b"A VaultRecord is already registered under Config for the provided vault ID.";
#[error(code = 5)]
const EUserLpCoinRecordAlreadyRegistered: vector<u8> =
    b"A UserLpCoinRecord is already registered under Config for the provided user LP coin ID.";
#[error(code = 6)]
const EUserLpCoinRecordDoesNotExist: vector<u8> =
    b"No UserLpCoinRecord is registered under Config for the provided user LP coin ID.";
#[error(code = 7)]
const ENotFrozen: vector<u8> = b"The Config is not frozen.";
#[error(code = 8)]
const EInvalidResumeVersion: vector<u8> =
    b"This package version cannot restore the frozen Config's resume version.";
#[error(code = 9)]
const EBadNewConfigVersion: vector<u8> =
    b"The new Config version must be greater than the current one.";

// === Types ===

public struct VaultRecord has copy, drop, store {
    vault_id: ID,
    owner_cap_id: ID,
    vault_metadata_id: ID,
    created_at_ms: u64,
}

public struct UserLpCoinRecord has copy, drop, store { user_lp_coin_id: ID, vault_id: ID }

public struct Config has key {
    id: UID,
    version: u64,
    collateral_pfs_tolerance: u64,
    max_lock_period: u64,
    max_force_withdraw_delay: u64,
    max_owner_fee_rate: u256,
    min_owner_lock_usd: u256,
    max_owner_lock_usd: u256,
    min_deposit_usd: u256,
    max_markets_in_vault: u64,
    max_pending_orders_per_position: u64,
    force_withdraw_pause_ms: u64,
    max_assistants_per_vault: u64,
    extra_fields: Bag,
}

// === Functions ===

#[allow(lint(self_transfer))]
public(package) fun create_config_and_share<T: drop>(witness: &T, ctx: &mut TxContext) {
    assert!(types::is_one_time_witness(witness), EConfigAlreadyCreated);

    let mut config = Config {
        id: object::new(ctx),
        version: 1,
        // Maximum collateral price age: 30 seconds.
        collateral_pfs_tolerance: 30_000,
        // Two months (a sixth of a 365.25-day year).
        max_lock_period: 5_259_600_000,
        // Two days.
        max_force_withdraw_delay: 172_800_000,
        // 20%, as an 18-decimal fixed-point number.
        max_owner_fee_rate: 200_000_000_000_000_000,
        // $0.95, $2 and $0.95, as 18-decimal fixed-point numbers.
        min_owner_lock_usd: 950_000_000_000_000_000,
        max_owner_lock_usd: 2_000_000_000_000_000_000,
        min_deposit_usd: 950_000_000_000_000_000,
        max_markets_in_vault: 20,
        max_pending_orders_per_position: 50,
        force_withdraw_pause_ms: 10_000,
        max_assistants_per_vault: 20,
        extra_fields: bag::new(ctx),
    };
    transfer::public_transfer(
        authority::create_package_admin_cap(witness, &mut config.id),
        ctx.sender(),
    );
    transfer::share_object(config)
}

public fun share(config: Config) {
    transfer::share_object(config)
}

public fun is_authority_cap_authorized<Role>(
    config: &Config,
    cap_id: ID,
): bool {
    cap_authority::is_cap_authorized<PACKAGE, Role>(&config.id, cap_id)
}

public fun is_frozen(config: &Config): bool {
    dynamic_field::exists(&config.id, keys::frozen_version_key())
}

public(package) fun collateral_pfs_tolerance(config: &Config): u64 {
    config.collateral_pfs_tolerance
}

public(package) fun max_lock_period(config: &Config): u64 {
    config.max_lock_period
}

public(package) fun max_force_withdraw_delay(config: &Config): u64 {
    config.max_force_withdraw_delay
}

public(package) fun max_owner_fee_rate(config: &Config): u256 {
    config.max_owner_fee_rate
}

public(package) fun min_owner_lock_usd(config: &Config): u256 {
    config.min_owner_lock_usd
}

public(package) fun max_owner_lock_usd(config: &Config): u256 {
    config.max_owner_lock_usd
}

public(package) fun min_deposit_usd(config: &Config): u256 {
    config.min_deposit_usd
}

public(package) fun max_markets_in_vault(config: &Config): u64 {
    config.max_markets_in_vault
}

public(package) fun max_pending_orders_per_position(config: &Config): u64 {
    config.max_pending_orders_per_position
}

public(package) fun force_withdraw_pause_ms(config: &Config): u64 {
    config.force_withdraw_pause_ms
}

public(package) fun max_assistants_per_vault(config: &Config): u64 {
    config.max_assistants_per_vault
}

public(package) fun user_lp_coin_record_vault_id(record: &UserLpCoinRecord): ID {
    record.vault_id
}

public(package) fun has_vault_record(config: &Config, vault_id: ID): bool {
    dynamic_field::exists(&config.id, keys::vault_record_key(vault_id))
}

public(package) fun user_lp_coin_record(
    config: &Config,
    user_lp_coin_id: ID,
): &UserLpCoinRecord {
    config.assert_user_lp_coin_record_exists(user_lp_coin_id);
    dynamic_field::borrow(&config.id, keys::user_lp_coin_record_key(user_lp_coin_id))
}

public(package) fun has_user_lp_coin_record(
    config: &Config,
    user_lp_coin_id: ID,
): bool {
    dynamic_field::exists(&config.id, keys::user_lp_coin_record_key(user_lp_coin_id))
}

public(package) fun assert_user_lp_coin_record_exists(
    config: &Config,
    user_lp_coin_id: ID,
) {
    assert!(config.has_user_lp_coin_record(user_lp_coin_id), EUserLpCoinRecordDoesNotExist)
}

public(package) fun register_vault(
    config: &mut Config,
    vault_id: ID,
    owner_cap_id: ID,
    vault_metadata_id: ID,
    created_at_ms: u64,
) {
    assert!(!config.has_vault_record(vault_id), EVaultRecordAlreadyRegistered);
    dynamic_field::add(
        &mut config.id,
        keys::vault_record_key(vault_id),
        VaultRecord { vault_id, owner_cap_id, vault_metadata_id, created_at_ms },
    )
}

public(package) fun register_user_lp_coin(
    config: &mut Config,
    user_lp_coin_id: ID,
    vault_id: ID,
) {
    assert!(!config.has_user_lp_coin_record(user_lp_coin_id), EUserLpCoinRecordAlreadyRegistered);
    dynamic_field::add(
        &mut config.id,
        keys::user_lp_coin_record_key(user_lp_coin_id),
        UserLpCoinRecord { user_lp_coin_id, vault_id },
    )
}

public(package) fun unregister_user_lp_coin(
    config: &mut Config,
    user_lp_coin_id: ID,
) {
    assert!(config.has_user_lp_coin_record(user_lp_coin_id), EUserLpCoinRecordDoesNotExist);
    let _: UserLpCoinRecord = dynamic_field::remove(
        &mut config.id,
        keys::user_lp_coin_record_key(user_lp_coin_id),
    );
}

public(package) fun create_package_assistant_cap_(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    let cap = authority::create_multiton_package_assistant_cap(&mut config.id, ctx);
    config.authorize_authority_cap(&cap);
    events::emit_create_package_assistant_cap(object::id(config), object::id(&cap));
    cap
}

public(package) fun create_package_pause_guardian_cap_(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, PAUSE_GUARDIAN> {
    let cap = authority::create_multiton_package_pause_guardian_cap(&mut config.id, ctx);
    config.authorize_authority_cap(&cap);
    events::emit_create_package_pause_guardian_cap(object::id(config), object::id(&cap));
    cap
}

public(package) fun create_package_maintenance_cap_(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, MAINTENANCE> {
    let cap = authority::create_multiton_package_maintenance_cap(&mut config.id, ctx);
    config.authorize_authority_cap(&cap);
    events::emit_create_package_maintenance_cap(object::id(config), object::id(&cap));
    cap
}

public(package) fun create_package_freeze_guardian_cap_(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    let cap = authority::create_multiton_package_freeze_guardian_cap(&mut config.id, ctx);
    config.authorize_authority_cap(&cap);
    events::emit_created_package_freeze_guardian_cap(object::id(config), object::id(&cap));
    cap
}

public fun unfreeze_package(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
) {
    assert!(config.is_frozen(), ENotFrozen);

    let resume_version: u64 = dynamic_field::remove(&mut config.id, keys::frozen_version_key());
    assert!(resume_version <= 1, EInvalidResumeVersion);
    config.version = resume_version;
    events::emit_unfroze(config.id.to_inner(), resume_version)
}

public fun freeze_package(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    config.assert_package_version();
    config.assert_is_active_package_freeze_guardian_cap(cap);

    // Park the current version and set an unreachable one, so every version check fails
    // until the package is unfrozen.
    let resume_version = config.version;
    dynamic_field::add(&mut config.id, keys::frozen_version_key(), resume_version);
    config.version = u64::max_value!();
    events::emit_froze(config.id.to_inner(), resume_version, object::id(cap))
}

public(package) fun deauthorize_package_authority_cap_<Role>(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    cap_id: ID,
) {
    authority::assert_is_not_admin<Role>();
    config.deauthorize_authority_cap_<Role>(cap_id);
    events::emit_revoked_package_authority_cap(
        object::id(config),
        type_name::with_defining_ids<Role>(),
        cap_id,
    )
}

public fun set_max_lock_period<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_lock_period: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    config.max_lock_period = max_lock_period
}

public fun set_max_force_withdraw_delay<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_force_withdraw_delay: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    assert!(config.force_withdraw_pause_ms <= max_force_withdraw_delay, EInvalidConfigValue);
    config.max_force_withdraw_delay = max_force_withdraw_delay
}

public fun set_max_owner_fee_rate<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_owner_fee_rate: u256,
) {
    config.assert_authority_cap_is_valid(cap);
    config.max_owner_fee_rate = max_owner_fee_rate
}

public fun set_min_owner_lock_usd<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    min_owner_lock_usd: u256,
) {
    config.assert_authority_cap_is_valid(cap);
    assert!(min_owner_lock_usd <= config.max_owner_lock_usd, EInvalidConfigValue);
    config.min_owner_lock_usd = min_owner_lock_usd
}

public fun set_max_owner_lock_usd<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_owner_lock_usd: u256,
) {
    config.assert_authority_cap_is_valid(cap);
    assert!(config.min_owner_lock_usd <= max_owner_lock_usd, EInvalidConfigValue);
    config.max_owner_lock_usd = max_owner_lock_usd
}

public fun set_min_deposit_usd<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    min_deposit_usd: u256,
) {
    config.assert_authority_cap_is_valid(cap);
    config.min_deposit_usd = min_deposit_usd
}

public fun set_max_markets_in_vault<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_markets_in_vault: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    config.max_markets_in_vault = max_markets_in_vault
}

public fun set_max_pending_orders_per_position<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_pending_orders_per_position: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    config.max_pending_orders_per_position = max_pending_orders_per_position
}

public fun set_force_withdraw_pause_ms<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    force_withdraw_pause_ms: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    assert!(force_withdraw_pause_ms <= config.max_force_withdraw_delay, EInvalidConfigValue);
    config.force_withdraw_pause_ms = force_withdraw_pause_ms
}

public fun set_max_assistants_per_vault<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    max_assistants_per_vault: u64,
) {
    config.assert_authority_cap_is_valid(cap);
    config.max_assistants_per_vault = max_assistants_per_vault
}

public(package) fun authorize_authority_cap<Role>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, Role>,
) {
    cap_authority::authorize_cap(&mut config.id, cap)
}

public(package) fun deauthorize_authority_cap_<Role>(config: &mut Config, cap_id: ID) {
    config.assert_authority_cap_id_is_authorized<Role>(cap_id);
    cap_authority::deauthorize_cap<PACKAGE, Role>(&mut config.id, cap_id)
}

/// ADMIN caps are always valid; ASSISTANT caps only while they are still authorized.
fun has_authority<Role>(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    cap.`for`() == authority::package_id() && (
        role == authority::type_name_of!<ADMIN>() || (
            role == authority::type_name_of!<ASSISTANT>() &&
                config.is_authority_cap_authorized<Role>(object::id(cap))
        )
    )
}

fun has_maintenance_authority(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, MAINTENANCE>,
): bool {
    cap.`for`() == authority::package_id() &&
        config.is_authority_cap_authorized<MAINTENANCE>(object::id(cap))
}

fun has_pause_guardian_authority(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, PAUSE_GUARDIAN>,
): bool {
    cap.`for`() == authority::package_id() &&
        config.is_authority_cap_authorized<PAUSE_GUARDIAN>(object::id(cap))
}

fun has_freeze_guardian_authority(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
): bool {
    cap.`for`() == authority::package_id() &&
        config.is_authority_cap_authorized<FREEZE_GUARDIAN>(object::id(cap))
}

public(package) fun upgrade_version(config: &mut Config) {
    let new_version = 1;
    assert!(new_version > config.version, EBadNewConfigVersion);
    config.version = new_version;
    events::emit_upgrade_config_version(config.id.to_inner(), new_version)
}

public fun assert_package_version(config: &Config) {
    assert!(config.version <= 1, EInvalidVersion)
}

public(package) fun assert_authority_cap_is_valid<ADMIN_OR_ASSISTANT>(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    config.assert_package_version();
    assert!(config.has_authority(cap), EInvalidAuthorityCap)
}

public(package) fun assert_is_active_package_pause_guardian_cap(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, PAUSE_GUARDIAN>,
) {
    config.assert_package_version();
    assert!(config.has_pause_guardian_authority(cap), EInvalidAuthorityCap)
}

public(package) fun assert_is_active_package_maintenance_cap(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, MAINTENANCE>,
) {
    config.assert_package_version();
    assert!(config.has_maintenance_authority(cap), EInvalidAuthorityCap)
}

public(package) fun assert_is_active_package_freeze_guardian_cap(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    assert!(config.has_freeze_guardian_authority(cap), EInvalidAuthorityCap)
}

public(package) fun assert_authority_cap_id_is_authorized<Role>(config: &Config, cap_id: ID) {
    assert!(config.is_authority_cap_authorized<Role>(cap_id), EInvalidAuthorityCap)
}
