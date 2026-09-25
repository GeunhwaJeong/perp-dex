// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module vendor::config;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::bag::{Self, Bag};
use haneul::dynamic_field;
use haneul::types;
use haneul::vec_set::{Self, VecSet};
use std::ascii::String;
use std::type_name;
use vendor::authority::{Self as vendor_authority, PACKAGE, REVOKE_VENDOR_GUARDIAN, VENDOR};
use vendor::events;

// === Errors and constants ===

const EInvalidVersion: u64 = 0;
const EConfigAlreadyCreated: u64 = 1;
const EInvalidAuthorityCap: u64 = 2;
const EVendorAdminCapDoesNotExist: u64 = 3;
const EAuthorityCapAlreadyAuthorized: u64 = 4;
const EKeyAlreadyRestricted: u64 = 5;
const EKeyNotRestricted: u64 = 6;
const CURRENT_VERSION: u64 = 1;

// === Types ===

public struct Config has key, store {
    id: UID,
    version: u64,
    restricted_keys: VecSet<String>,
    extra_fields: Bag,
}

// === Functions ===

public(package) fun new<T: drop>(witness: &T, ctx: &mut TxContext): Config {
    assert!(types::is_one_time_witness(witness), EConfigAlreadyCreated);
    Config {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        restricted_keys: vec_set::empty(),
        extra_fields: bag::new(ctx),
    }
}

public(package) fun borrow_mut_id(
    config: &mut Config,
): &mut UID {
    &mut config.id
}

public fun version(
    config: &Config,
): u64 {
    config.version
}

public fun is_restricted_key(
    config: &Config,
    key: &String,
): bool {
    config.restricted_keys.contains(key)
}

public fun is_authority_cap_active<Context, Role>(
    config: &Config,
    cap_id: ID,
): bool {
    authority::is_cap_authorized<Context, Role>(&config.id, cap_id)
}

public fun create_package_assistant_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    config.assert_package_version();
    let assistant_cap = vendor_authority::create_package_assistant_cap(&mut config.id, ctx);
    config.authorize_authority_cap(&assistant_cap);
    assistant_cap
}

public fun deauthorize_package_assistant_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    cap_id: ID,
) {
    config.assert_package_version();
    config.deauthorize_authority_cap<ASSISTANT>(cap_id)
}

public fun upgrade_version<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert!(config.version == CURRENT_VERSION - 1, EInvalidVersion);
    config.assert_has_active_package_authority(cap);
    config.version = CURRENT_VERSION
}

entry fun register_vendor<VendorKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    recipient: address,
) {
    config.assert_package_version();
    config.assert_has_active_package_authority(cap);
    let admin_cap = vendor_authority::create_vendor_admin_cap<VendorKey>(&mut config.id);
    config.authorize_authority_cap(&admin_cap);
    transfer::public_transfer(admin_cap, recipient)
}

public fun create_package_revoke_vendor_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    config.assert_package_version();
    let guardian_cap = vendor_authority::create_package_revoke_vendor_guardian_cap(
        &mut config.id,
        ctx,
    );
    config.authorize_authority_cap(&guardian_cap);
    events::emit_create_package_revoke_vendor_guardian_cap_event(object::id(&guardian_cap));
    guardian_cap
}

public fun deauthorize_package_revoke_vendor_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    cap_id: ID,
) {
    config.assert_package_version();
    config.deauthorize_authority_cap<REVOKE_VENDOR_GUARDIAN>(cap_id);
    events::emit_deauthorize_package_revoke_vendor_guardian_cap_event(cap_id)
}

public fun reauthorize_vendor_admin_cap<VendorKey>(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
) {
    config.assert_package_version();
    assert!(
        authority::exists<VENDOR<VendorKey>, ADMIN>(&config.id),
        EVendorAdminCapDoesNotExist,
    );
    let cap_id = authority::derived_cap_id<VENDOR<VendorKey>, ADMIN>(&config.id);
    assert!(
        !config.is_vendor_authority_cap_authorized<VendorKey, ADMIN>(cap_id),
        EAuthorityCapAlreadyAuthorized,
    );
    dynamic_field::add(
        &mut config.id,
        authority::authorized_authority_cap_key<VENDOR<VendorKey>, ADMIN>(cap_id),
        true,
    );
    events::emit_reauthorize_vendor_admin_cap_event(
        type_name::with_defining_ids<VendorKey>(),
        cap_id,
    )
}

public fun add_restricted_key<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    key: String,
) {
    config.assert_package_version();
    config.assert_has_active_package_authority(cap);
    assert!(!config.restricted_keys.contains(&key), EKeyAlreadyRestricted);
    config.restricted_keys.insert(key)
}

public fun remove_restricted_key<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    key: String,
) {
    config.assert_package_version();
    config.assert_has_active_package_authority(cap);
    assert!(config.restricted_keys.contains(&key), EKeyNotRestricted);
    config.restricted_keys.remove(&key)
}

public fun guardian_deauthorize_vendor_authority_cap<VendorKey, Role>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN>,
    cap_id: ID,
) {
    config.assert_package_version();
    assert!(
        config.is_authority_cap_authorized<REVOKE_VENDOR_GUARDIAN>(object::id(cap)),
        EInvalidAuthorityCap,
    );
    config.deauthorize_vendor_authority_cap<VendorKey, Role>(cap_id);
    events::emit_guardian_revoke_vendor_authority_cap_event(
        type_name::with_defining_ids<VendorKey>(),
        type_name::with_defining_ids<Role>(),
        cap_id,
    )
}

public fun create_vendor_assistant_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    config.assert_package_version();
    config.assert_has_active_vendor_authority(admin_cap);
    let assistant_cap =
        vendor_authority::create_vendor_assistant_cap<VendorKey>(&mut config.id, ctx);
    config.authorize_authority_cap(&assistant_cap);
    assistant_cap
}

public fun deauthorize_vendor_assistant_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    cap_id: ID,
) {
    config.assert_package_version();
    config.assert_has_active_vendor_authority(admin_cap);
    config.deauthorize_vendor_authority_cap<VendorKey, ASSISTANT>(cap_id)
}

public fun assert_package_version(config: &Config) {
    assert!(config.version == CURRENT_VERSION, EInvalidVersion)
}

public fun assert_has_active_package_authority<Role>(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, Role>,
) {
    assert!(config.has_package_authority(cap), EInvalidAuthorityCap)
}

public fun assert_has_active_vendor_authority<VendorKey, Role>(
    config: &Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, Role>,
) {
    assert!(config.has_vendor_authority(cap), EInvalidAuthorityCap)
}

// Admins are always authorized; assistants only while their cap is still registered on the config.
public(package) fun has_package_authority<Role>(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    {
        let role = role;
        let admin = type_name::with_defining_ids<ADMIN>();
        role == admin
    } || {
        let role = role;
        let assistant = type_name::with_defining_ids<ASSISTANT>();
        role == assistant && config.is_authority_cap_authorized<ASSISTANT>(object::id(cap))
    }
}

public(package) fun has_vendor_authority<VendorKey, Role>(
    config: &Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    {
        let role = role;
        let admin = type_name::with_defining_ids<ADMIN>();
        role == admin
            && config.is_vendor_authority_cap_authorized<VendorKey, ADMIN>(object::id(cap))
    } || {
        let role = role;
        let assistant = type_name::with_defining_ids<ASSISTANT>();
        role == assistant
            && config.is_vendor_authority_cap_authorized<VendorKey, ASSISTANT>(object::id(cap))
    }
}

public(package) fun is_vendor_authority_cap_authorized<VendorKey, Role>(
    config: &Config,
    cap_id: ID,
): bool {
    authority::is_cap_authorized<VENDOR<VendorKey>, Role>(&config.id, cap_id)
}

fun is_authority_cap_authorized<Role>(
    config: &Config,
    cap_id: ID,
): bool {
    authority::is_cap_authorized<PACKAGE, Role>(&config.id, cap_id)
}

fun authorize_authority_cap<Context, Role>(
    config: &mut Config,
    cap: &AuthorityCap<Context, Role>,
) {
    authority::authorize_cap(&mut config.id, cap)
}

fun deauthorize_authority_cap<Role>(
    config: &mut Config,
    cap_id: ID,
) {
    assert!(config.is_authority_cap_authorized<Role>(cap_id), EInvalidAuthorityCap);
    authority::deauthorize_cap<PACKAGE, Role>(&mut config.id, cap_id)
}

fun deauthorize_vendor_authority_cap<VendorKey, Role>(
    config: &mut Config,
    cap_id: ID,
) {
    assert!(
        config.is_vendor_authority_cap_authorized<VendorKey, Role>(cap_id),
        EInvalidAuthorityCap,
    );
    authority::deauthorize_cap<VENDOR<VendorKey>, Role>(&mut config.id, cap_id)
}
