// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::config;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::dynamic_field;
use haneul::types;
use oracle_aggregator::authority::{
    Self as oracle_authority,
    FREEZE_GUARDIAN,
    MAINTENANCE,
    PACKAGE,
    REVOKE_VENDOR_GUARDIAN,
    SourceCap,
    VENDOR,
};
use oracle_aggregator::events;
use std::type_name;
use std::u64;
use vendor::metadata::VendorMetadata;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EConfigAlreadyCreated: vector<u8> = b"The package config has already been created.";
#[error(code = 1)]
const EInvalidVersion: vector<u8> =
    b"This package version cannot be used for the requested action.";
#[error(code = 2)]
const EInactiveAuthorityCap: vector<u8> =
    b"The authority cap is inactive and cannot be used for the requested action.";
#[error(code = 3)]
const ESourceAlreadyRegistered: vector<u8> = b"The source has already been registered.";
#[error(code = 4)]
const EVendorRegistrationNotApproved: vector<u8> =
    b"Vendor registration is gated and this vendor has not been approved to register.";
#[error(code = 5)]
const EVendorAdminCapDoesNotExist: vector<u8> =
    b"The vendor admin cap has not been created for this vendor.";
#[error(code = 6)]
const EAuthorityCapAlreadyAuthorized: vector<u8> =
    b"The authority cap already holds active authority.";
#[error(code = 7)]
const ENotFrozen: vector<u8> = b"The package is not frozen.";
#[error(code = 8)]
const EInvalidResumeVersion: vector<u8> =
    b"The stored resume version does not match this package's version.";
macro fun current_version(): u64 { 1 }

// === Types ===

public struct RegisteredSource<phantom SourceKey> has copy, drop, store {}

public struct VendorRegistrationOpen has copy, drop, store {}

public struct FrozenVersion has copy, drop, store {}

public struct Config has key {
    id: UID,
    version: u64,
    next_storage_id: u32,
    next_source_id: u16,
}

// === Functions ===

public(package) fun create_config<T: drop>(witness: &T, ctx: &mut TxContext): Config {
    assert!(types::is_one_time_witness(witness), EConfigAlreadyCreated);
    Config {
        id: object::new(ctx),
        version: current_version!(),
        next_storage_id: 0,
        next_source_id: 0,
    }
}

public fun share(config: Config) {
    transfer::share_object(config)
}

public(package) fun borrow_mut_id(config: &mut Config): &mut UID {
    &mut config.id
}

public(package) fun id(config: &Config): ID {
    config.id.to_inner()
}

public fun is_vendor_registration_open(config: &Config): bool {
    let key = VendorRegistrationOpen {};
    if (dynamic_field::exists_with_type<VendorRegistrationOpen, bool>(&config.id, key)) {
        *dynamic_field::borrow<VendorRegistrationOpen, bool>(&config.id, key)
    } else {
        false
    }
}

public fun is_authority_cap_active<Context, Role>(
    config: &Config,
    cap_id: ID,
): bool {
    authority::is_cap_authorized<Context, Role>(&config.id, cap_id)
}

public fun is_frozen(config: &Config): bool {
    dynamic_field::exists_with_type<FrozenVersion, u64>(
        &config.id,
        FrozenVersion {},
    )
}

public fun unfreeze_package(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
) {
    assert!(config.is_frozen(), ENotFrozen);
    let resume_version = dynamic_field::remove<FrozenVersion, u64>(
        &mut config.id,
        FrozenVersion {},
    );
    assert!(resume_version <= current_version!(), EInvalidResumeVersion);

    config.version = resume_version;
    events::emit_unfroze(config.id.to_inner(), resume_version)
}

public fun new_package_assistant_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    config.assert_package_version();
    let assistant_cap = oracle_authority::create_multiton_package_assistant_cap(
        &mut config.id,
        ctx,
    );
    authority::authorize_cap(&mut config.id, &assistant_cap);
    assistant_cap
}

public fun revoke_package_assistant_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    assistant_cap: ID,
) {
    config.assert_package_version();
    assert!(
        authority::is_cap_authorized<PACKAGE, ASSISTANT>(&config.id, assistant_cap),
        EInactiveAuthorityCap,
    );
    authority::deauthorize_cap<PACKAGE, ASSISTANT>(&mut config.id, assistant_cap)
}

public fun new_package_revoke_vendor_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    config.assert_package_version();
    let guardian_cap = oracle_authority::create_package_revoke_vendor_guardian_cap(
        &mut config.id,
        ctx,
    );
    authority::authorize_cap(&mut config.id, &guardian_cap);
    events::emit_created_package_revoke_vendor_guardian_cap(object::id(&guardian_cap));
    guardian_cap
}

public fun revoke_package_revoke_vendor_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    guardian_cap: ID,
) {
    config.assert_package_version();
    assert!(
        authority::is_cap_authorized<PACKAGE, REVOKE_VENDOR_GUARDIAN>(&config.id, guardian_cap),
        EInactiveAuthorityCap,
    );
    authority::deauthorize_cap<PACKAGE, REVOKE_VENDOR_GUARDIAN>(&mut config.id, guardian_cap)
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
    // The vendor admin cap id is derived from the config, so no cap object is needed here.
    let admin_cap_id = authority::derived_cap_id<VENDOR<VendorKey>, ADMIN>(&config.id);
    assert!(
        !authority::is_cap_authorized<VENDOR<VendorKey>, ADMIN>(&config.id, admin_cap_id),
        EAuthorityCapAlreadyAuthorized,
    );

    dynamic_field::add(
        &mut config.id,
        authority::authorized_authority_cap_key<VENDOR<VendorKey>, ADMIN>(admin_cap_id),
        true,
    );
    events::emit_reauthorized_vendor_admin_cap(
        type_name::with_defining_ids<VendorKey>(),
        admin_cap_id,
    )
}

public fun new_package_freeze_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    config.assert_package_version();
    let guardian_cap = oracle_authority::create_package_freeze_guardian_cap(&mut config.id, ctx);
    authority::authorize_cap(&mut config.id, &guardian_cap);
    events::emit_created_package_freeze_guardian_cap(object::id(&guardian_cap));
    guardian_cap
}

public fun revoke_package_freeze_guardian_cap(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    guardian_cap: ID,
) {
    config.assert_package_version();
    assert!(
        authority::is_cap_authorized<PACKAGE, FREEZE_GUARDIAN>(&config.id, guardian_cap),
        EInactiveAuthorityCap,
    );
    authority::deauthorize_cap<PACKAGE, FREEZE_GUARDIAN>(&mut config.id, guardian_cap)
}

public fun freeze_package(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    config.assert_package_version();
    assert!(
        authority::is_cap_authorized<PACKAGE, FREEZE_GUARDIAN>(&config.id, object::id(cap)),
        EInactiveAuthorityCap,
    );

    let resume_version = config.version;
    dynamic_field::add(&mut config.id, FrozenVersion {}, resume_version);
    // A version above `current_version!()` makes every `assert_package_version` call abort
    // until `unfreeze_package` restores the stored one.
    config.version = u64::max_value!();
    events::emit_froze(config.id.to_inner(), resume_version, object::id(cap))
}

public fun guardian_revoke_vendor_authority_cap<VendorKey, Role>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN>,
    cap_id: ID,
) {
    config.assert_package_version();
    assert!(
        authority::is_cap_authorized<PACKAGE, REVOKE_VENDOR_GUARDIAN>(&config.id, object::id(cap)),
        EInactiveAuthorityCap,
    );
    assert!(
        config.has_active_vendor_authority_cap<VendorKey, Role>(cap_id),
        EInactiveAuthorityCap,
    );

    authority::deauthorize_cap<VENDOR<VendorKey>, Role>(&mut config.id, cap_id);
    events::emit_guardian_revoked_vendor_authority_cap(
        type_name::with_defining_ids<VendorKey>(),
        type_name::with_defining_ids<Role>(),
        cap_id,
    )
}

entry fun set_vendor_registration(
    config: &mut Config,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    open: bool,
) {
    config.assert_package_version();
    let id = &mut config.id;
    let key = VendorRegistrationOpen {};
    if (!dynamic_field::exists(id, key)) {
        dynamic_field::add(id, key, open)
    };
    let registration_open = dynamic_field::borrow_mut(id, key);
    *registration_open = open;
    events::emit_set_vendor_registration(open)
}

public fun upgrade_version<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert!(config.version < current_version!(), EInvalidVersion);
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);
    config.version = current_version!()
}

public(package) fun new_source_id<SourceKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
): SourceCap {
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);

    let key = RegisteredSource<SourceKey> {};
    assert!(
        !dynamic_field::exists_with_type<RegisteredSource<SourceKey>, u16>(&config.id, key),
        ESourceAlreadyRegistered,
    );
    let source_id = config.next_source_id;
    config.next_source_id = source_id + 1;
    dynamic_field::add(&mut config.id, key, source_id);
    events::emit_added_authorization(source_id);
    oracle_authority::new_source_cap(source_id)
}

public fun set_authorized<ADMIN_OR_ASSISTANT>(
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    source_cap: &mut SourceCap,
    authorized: bool,
) {
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);
    source_cap.set_source_cap_authorized(authorized);
    if (authorized) {
        events::emit_added_authorization(source_cap.source_id())
    } else {
        events::emit_removed_authorization(source_cap.source_id())
    }
}

public fun register_vendor<VendorKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<vendor::authority::VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    vendor_config: &vendor::config::Config,
    metadata: &VendorMetadata<VendorKey>,
): AuthorityCap<VENDOR<VendorKey>, ADMIN> {
    config.assert_package_version();
    oracle_authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    vendor_config.assert_has_active_vendor_authority(cap);
    assert!(
        config.is_vendor_registration_open()
            || metadata.is_domain_registration_approved<VendorKey, PACKAGE>(),
        EVendorRegistrationNotApproved,
    );

    let admin_cap = oracle_authority::create_vendor_admin_cap<VendorKey>(&mut config.id);
    config.authorize_vendor_authority_cap(&admin_cap);
    events::emit_registered_vendor(
        type_name::with_defining_ids<VendorKey>(),
        object::id(&admin_cap),
    );
    admin_cap
}

public fun new_vendor_assistant_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    config.assert_package_version();
    config.assert_vendor_authority_cap_is_valid(admin_cap);
    let assistant_cap = oracle_authority::create_vendor_assistant_cap<VendorKey>(
        &mut config.id,
        ctx,
    );
    config.authorize_vendor_authority_cap(&assistant_cap);
    assistant_cap
}

public fun revoke_vendor_assistant_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    assistant_cap: ID,
) {
    config.revoke_vendor_authority_cap<VendorKey, ASSISTANT>(admin_cap, assistant_cap)
}

public fun new_vendor_maintenance_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, MAINTENANCE> {
    config.assert_package_version();
    config.assert_vendor_authority_cap_is_valid(admin_cap);
    let maintenance_cap = oracle_authority::create_vendor_maintenance_cap<VendorKey>(
        &mut config.id,
        ctx,
    );
    config.authorize_vendor_authority_cap(&maintenance_cap);
    maintenance_cap
}

public fun revoke_vendor_maintenance_cap<VendorKey>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    maintenance_cap: ID,
) {
    config.revoke_vendor_authority_cap<VendorKey, MAINTENANCE>(admin_cap, maintenance_cap)
}

public(package) fun has_active_package_authority<Role>(
    config: &Config,
    authority_cap: &AuthorityCap<PACKAGE, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    let given = role;
    let admin = type_name::with_defining_ids<ADMIN>();
    // The package admin cap is a singleton that is never deauthorized, so holding it suffices.
    if (given == admin) {
        true
    } else {
        let given = role;
        let assistant = type_name::with_defining_ids<ASSISTANT>();
        if (given == assistant) {
            authority::is_cap_authorized<PACKAGE, ASSISTANT>(&config.id, object::id(authority_cap))
        } else {
            false
        }
    }
}

public(package) fun has_vendor_authority<VendorKey, Role>(
    config: &Config,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    let given = role;
    let admin = type_name::with_defining_ids<ADMIN>();
    let is_active_admin = if (given == admin) {
        config.has_active_vendor_authority_cap<VendorKey, ADMIN>(object::id(authority_cap))
    } else {
        false
    };
    let has_authority;
    if (is_active_admin) {
        has_authority = true;
    } else {
        let given = role;
        let assistant = type_name::with_defining_ids<ASSISTANT>();
        let is_active_assistant = if (given == assistant) {
            config.has_active_vendor_authority_cap<VendorKey, ASSISTANT>(object::id(authority_cap))
        } else {
            false
        };
        if (is_active_assistant) {
            has_authority = true;
        } else {
            let given = role;
            let maintenance = type_name::with_defining_ids<MAINTENANCE>();
            has_authority = if (given == maintenance) {
                config.has_active_vendor_authority_cap<VendorKey, MAINTENANCE>(
                    object::id(authority_cap),
                )
            } else {
                false
            };
        }
    };
    has_authority
}

public fun assert_package_version(config: &Config) {
    if (config.version > current_version!()) {
        abort EInvalidVersion
    }
}

public fun assert_package_authority_cap_is_valid<Role>(
    config: &Config,
    authority_cap: &AuthorityCap<PACKAGE, Role>,
) {
    assert!(config.has_active_package_authority(authority_cap), EInactiveAuthorityCap)
}

public fun assert_vendor_authority_cap_is_valid<VendorKey, Role>(
    config: &Config,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, Role>,
) {
    assert!(config.has_vendor_authority(authority_cap), EInactiveAuthorityCap)
}

fun authorize_vendor_authority_cap<VendorKey, Role>(
    config: &mut Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, Role>,
) {
    authority::authorize_cap(&mut config.id, cap)
}

fun revoke_vendor_authority_cap<VendorKey, Role>(
    config: &mut Config,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    cap: ID,
) {
    config.assert_package_version();
    oracle_authority::assert_is_not_admin<Role>();
    config.assert_vendor_authority_cap_is_valid(admin_cap);
    assert!(config.has_active_vendor_authority_cap<VendorKey, Role>(cap), EInactiveAuthorityCap);
    authority::deauthorize_cap<VENDOR<VendorKey>, Role>(&mut config.id, cap)
}

fun has_active_vendor_authority_cap<VendorKey, Role>(
    config: &Config,
    cap: ID,
): bool {
    authority::is_cap_authorized<VENDOR<VendorKey>, Role>(&config.id, cap)
}

public(package) fun inc_storage_id(config: &mut Config): u32 {
    let storage_id = config.next_storage_id;
    config.next_storage_id = storage_id + 1;
    storage_id
}
