// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::authority;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::address;
use haneul::dynamic_field;
use haneul::types;
use std::type_name;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EInvalidAuthorityRole: vector<u8> = b"This function does not accept the provided authority role.";
#[error(code = 1)]
const EPackageAuthorityCapAlreadyCreated: vector<u8> =
    b"The package authority cap has already been created.";
#[error(code = 2)]
const EVendorAuthorityCapAlreadyCreated: vector<u8> =
    b"The vendor authority cap has already been created.";
#[error(code = 3)]
const EInvalidVendorAuthorization: vector<u8> =
    b"The price feed storage is not authorized for the provided vendor.";

// === Types ===

public struct PACKAGE has drop {}

public struct VENDOR<phantom VendorKey> has drop {}

public struct MAINTENANCE has drop {}

public struct REVOKE_VENDOR_GUARDIAN has drop {}

public struct FREEZE_GUARDIAN has drop {}

public struct VendorAuthKey has copy, drop, store {}

public struct VendorSourceCap<phantom VendorKey> has store {}

public struct SourceCap has store { source_id: u16, authorized: bool }

// === Functions ===

#[allow(lint(self_transfer))]
public(package) fun create_package_admin_cap_and_keep<T: drop>(
    witness: &T,
    config_id: &mut UID,
    ctx: &TxContext,
) {
    assert!(types::is_one_time_witness(witness), EPackageAuthorityCapAlreadyCreated);
    assert!(!authority::exists<PACKAGE, ADMIN>(config_id), EPackageAuthorityCapAlreadyCreated);

    let id = config_id;
    let context = &PACKAGE {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    let admin_cap = authority::new_admin_cap(id, context, package_id);
    authority::authorize_cap(config_id, &admin_cap);
    transfer::public_transfer(admin_cap, ctx.sender())
}

public(package) fun create_multiton_package_assistant_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    let id = config_id;
    let context = &PACKAGE {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton_assistant_cap(id, context, package_id, ctx)
}

public(package) fun create_vendor_admin_cap<VendorKey>(
    config_id: &mut UID,
): AuthorityCap<VENDOR<VendorKey>, ADMIN> {
    assert!(
        !authority::exists<VENDOR<VendorKey>, ADMIN>(config_id),
        EVendorAuthorityCapAlreadyCreated,
    );

    let id = config_id;
    let context = &VENDOR {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_admin_cap(id, context, package_id)
}

public(package) fun create_vendor_assistant_cap<VendorKey>(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    let id = config_id;
    let context = &VENDOR {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton_assistant_cap(id, context, package_id, ctx)
}

public(package) fun create_vendor_maintenance_cap<VendorKey>(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, MAINTENANCE> {
    let id = config_id;
    let context = &VENDOR {};
    let role = &MAINTENANCE {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton(id, context, role, package_id, ctx)
}

public(package) fun create_package_revoke_vendor_guardian_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    let id = config_id;
    let context = &PACKAGE {};
    let role = &REVOKE_VENDOR_GUARDIAN {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton(id, context, role, package_id, ctx)
}

public(package) fun create_package_freeze_guardian_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    let id = config_id;
    let context = &PACKAGE {};
    let role = &FREEZE_GUARDIAN {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton(id, context, role, package_id, ctx)
}

public fun source_id(cap: &SourceCap): u16 {
    cap.source_id
}

public fun is_authorized(cap: &SourceCap): bool {
    cap.authorized
}

public(package) fun new_source_cap(source_id: u16): SourceCap {
    SourceCap { source_id, authorized: true }
}

public(package) fun set_source_cap_authorized(cap: &mut SourceCap, authorized: bool) {
    cap.authorized = authorized
}

public fun has_vendor_authorization<VendorKey>(id: &UID): bool {
    dynamic_field::exists_with_type<VendorAuthKey, VendorSourceCap<VendorKey>>(
        id,
        VendorAuthKey {},
    )
}

public(package) fun add_vendor_authorization<VendorKey>(id: &mut UID) {
    dynamic_field::add(
        id,
        VendorAuthKey {},
        VendorSourceCap<VendorKey> {},
    )
}

public fun assert_is_admin_or_assistant<Role>() {
    let role = type_name::with_defining_ids<Role>();
    let given = role;
    let assistant = type_name::with_defining_ids<ASSISTANT>();
    let is_admin_or_assistant = if (given == assistant) {
        true
    } else {
        let given = role;
        let admin = type_name::with_defining_ids<ADMIN>();
        given == admin
    };
    assert!(is_admin_or_assistant, EInvalidAuthorityRole)
}

public fun assert_is_admin_or_maintenance<Role>() {
    let role = type_name::with_defining_ids<Role>();
    let given = role;
    let maintenance = type_name::with_defining_ids<MAINTENANCE>();
    let is_admin_or_maintenance = if (given == maintenance) {
        true
    } else {
        let given = role;
        let admin = type_name::with_defining_ids<ADMIN>();
        given == admin
    };
    assert!(is_admin_or_maintenance, EInvalidAuthorityRole)
}

public(package) fun assert_is_not_admin<Role>() {
    let role = type_name::with_defining_ids<Role>();
    let admin = type_name::with_defining_ids<ADMIN>();
    assert!(!(role == admin), EInvalidAuthorityRole)
}

public(package) fun assert_has_active_vendor_authority<VendorKey>(id: &UID) {
    assert!(has_vendor_authorization<VendorKey>(id), EInvalidVendorAuthorization)
}
