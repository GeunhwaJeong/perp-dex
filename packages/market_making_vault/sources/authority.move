// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::authority;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::address;
use haneul::types;
use std::type_name::{Self, TypeName};

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EInvalidAuthorityRole: vector<u8> = b"This function only accepts ADMIN or ASSISTANT authority roles.";
#[error(code = 1)]
const EPackageAuthorityCapAlreadyCreated: vector<u8> =
    b"The package authority cap has already been created.";
#[error(code = 2)]
const EVaultAuthorityCapAlreadyCreated: vector<u8> =
    b"The vault authority cap has already been created.";

// === Types ===

public struct PACKAGE has drop {}

public struct VAULT<phantom LpCoin> has drop {}

public struct MAINTENANCE has drop {}

public struct PAUSE_GUARDIAN has drop {}

public struct TREASURY has drop {}

public struct FREEZE_GUARDIAN has drop {}

// === Macros ===

/// The `TypeName` of `$T` (with defining IDs).
public(package) macro fun type_name_of<$T>(): TypeName {
    type_name::with_defining_ids<$T>()
}

/// This package's ID, read from the defining address of the `PACKAGE` witness type.
macro fun package_object_id(): ID {
    object::id_from_address(address::from_ascii_bytes(
        &type_name::with_defining_ids<PACKAGE>().address_string().into_bytes(),
    ))
}

// === Functions ===

public(package) fun create_package_admin_cap<T: drop>(
    witness: &T,
    config_id: &mut UID,
): AuthorityCap<PACKAGE, ADMIN> {
    assert!(types::is_one_time_witness(witness), EPackageAuthorityCapAlreadyCreated);
    assert!(!authority::exists<PACKAGE, ADMIN>(config_id), EPackageAuthorityCapAlreadyCreated);

    let cap = authority::new_admin_cap(
        config_id,
        &PACKAGE {},
        package_object_id!(),
    );
    authority::authorize_cap(config_id, &cap);
    cap
}

public(package) fun create_multiton_package_assistant_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    authority::new_multiton_assistant_cap(
        config_id,
        &PACKAGE {},
        package_object_id!(),
        ctx,
    )
}

public(package) fun create_multiton_package_pause_guardian_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, PAUSE_GUARDIAN> {
    authority::new_multiton(
        config_id,
        &PACKAGE {},
        &PAUSE_GUARDIAN {},
        package_object_id!(),
        ctx,
    )
}

public(package) fun create_multiton_package_maintenance_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, MAINTENANCE> {
    authority::new_multiton(
        config_id,
        &PACKAGE {},
        &MAINTENANCE {},
        package_object_id!(),
        ctx,
    )
}

public(package) fun create_multiton_package_freeze_guardian_cap(
    config_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    authority::new_multiton(
        config_id,
        &PACKAGE {},
        &FREEZE_GUARDIAN {},
        package_object_id!(),
        ctx,
    )
}

public(package) fun create_vault_admin_cap<LpCoin>(
    vault_id: &mut UID,
): AuthorityCap<VAULT<LpCoin>, ADMIN> {
    assert!(!authority::exists<VAULT<LpCoin>, ADMIN>(vault_id), EVaultAuthorityCapAlreadyCreated);

    let vault_inner_id = vault_id.to_inner();
    let cap = authority::new_admin_cap(
        vault_id,
        &VAULT<LpCoin> {},
        vault_inner_id,
    );
    authority::authorize_cap(vault_id, &cap);
    cap
}

public(package) fun create_vault_assistant_cap<LpCoin>(
    vault_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<LpCoin>, ASSISTANT> {
    let vault_inner_id = vault_id.to_inner();
    authority::new_multiton_assistant_cap(
        vault_id,
        &VAULT<LpCoin> {},
        vault_inner_id,
        ctx,
    )
}

public(package) fun create_vault_treasury_cap<LpCoin>(
    vault_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<LpCoin>, TREASURY> {
    let vault_inner_id = vault_id.to_inner();
    authority::new_multiton(
        vault_id,
        &VAULT<LpCoin> {},
        &TREASURY {},
        vault_inner_id,
        ctx,
    )
}

public(package) fun assert_is_not_admin<Role>() {
    assert!(!(type_name_of!<Role>() == type_name_of!<ADMIN>()), EInvalidAuthorityRole)
}

public(package) fun package_id(): ID {
    package_object_id!()
}
