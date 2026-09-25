// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module vendor::authority;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::address;
use haneul::types;
use std::type_name;

// === Errors and constants (original names from the published interface) ===

const EAuthorityCapAlreadyCreated: u64 = 0;

// === Types ===

public struct PACKAGE has drop {}

public struct VENDOR<phantom VendorKey> has drop {}

public struct REVOKE_VENDOR_GUARDIAN has drop {}

// === Functions ===

#[allow(lint(self_transfer))]
public(package) fun create_package_admin_cap_and_keep<T: drop>(
    witness: &T,
    config_id: &mut UID,
    ctx: &TxContext,
) {
    assert!(types::is_one_time_witness(witness), EAuthorityCapAlreadyCreated);
    assert!(!authority::exists<PACKAGE, ADMIN>(config_id), EAuthorityCapAlreadyCreated);
    let id = config_id;
    let package_witness = &PACKAGE {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    let admin_cap = authority::new_admin_cap(id, package_witness, package_id);
    authority::authorize_cap(config_id, &admin_cap);
    transfer::public_transfer(admin_cap, ctx.sender())
}

public(package) fun create_package_assistant_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    let id = config_id;
    let package_witness = &PACKAGE {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton_assistant_cap(id, package_witness, package_id, ctx)
}

public(package) fun create_vendor_admin_cap<VendorKey>(
    config_id: &mut UID,
): AuthorityCap<VENDOR<VendorKey>, ADMIN> {
    assert!(
        !authority::exists<VENDOR<VendorKey>, ADMIN>(config_id),
        EAuthorityCapAlreadyCreated,
    );
    let id = config_id;
    let vendor_witness = &VENDOR<VendorKey> {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_admin_cap(id, vendor_witness, package_id)
}

public(package) fun create_vendor_assistant_cap<VendorKey>(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    let id = config_id;
    let vendor_witness = &VENDOR<VendorKey> {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton_assistant_cap(id, vendor_witness, package_id, ctx)
}

public(package) fun create_package_revoke_vendor_guardian_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    let id = config_id;
    let package_witness = &PACKAGE {};
    let guardian_witness = &REVOKE_VENDOR_GUARDIAN {};
    let package_id = object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ));
    authority::new_multiton(id, package_witness, guardian_witness, package_id, ctx)
}
