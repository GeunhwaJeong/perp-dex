// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::authority;

use authority_cap::authority::{Self, ADMIN, ASSISTANT, AuthorityCap};
use haneul::address;
use haneul::types;
use std::internal;
use std::type_name;

// === Errors and constants ===

const EInvalidAuthorityRole: u64 = 6100;
const ENotOneTimeWitness: u64 = 66;

// === Types ===

public struct PACKAGE has drop {}

public struct VENDOR<phantom VendorKey> has drop {}

public struct ACCOUNT has drop {}

public struct ADL has drop {}

public struct PAUSE_GUARDIAN has drop {}

public struct TREASURY has drop {}

public struct MAINTENANCE has drop {}

public struct REVOKE_VENDOR_GUARDIAN has drop {}

public struct FREEZE_GUARDIAN has drop {}

// === Functions ===

#[allow(lint(self_transfer))]
public(package) fun create_package_admin_cap_and_keep<T: drop>(
    witness: &T,
    registry_id: &mut UID,
    ctx: &TxContext,
) {
    assert!(types::is_one_time_witness(witness), ENotOneTimeWitness);
    let cap = authority::new_admin_cap(
        registry_id,
        &PACKAGE {},
        this_package(),
    );
    authority::authorize_cap(registry_id, &cap);
    transfer::public_transfer(cap, ctx.sender())
}

public(package) fun create_package_assistant_cap(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    authority::new_multiton_assistant_cap(
        registry_id,
        &PACKAGE {},
        this_package(),
        ctx,
    )
}

public(package) fun create_package_adl_cap(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ADL> {
    authority::new_multiton(
        registry_id,
        &PACKAGE {},
        &ADL {},
        this_package(),
        ctx,
    )
}

public(package) fun create_package_pause_guardian_cap(
    registry_id: &mut UID,
    ctx: &mut TxContext
): AuthorityCap<PACKAGE, PAUSE_GUARDIAN> {
    authority::new_multiton(
        registry_id,
        &PACKAGE {},
        &PAUSE_GUARDIAN {},
        this_package(),
        ctx,
    )
}

public(package) fun create_package_revoke_vendor_guardian_cap(
    registry_id: &mut UID,
    ctx: &mut TxContext
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    authority::new_multiton(
        registry_id,
        &PACKAGE {},
        &REVOKE_VENDOR_GUARDIAN {},
        this_package(),
        ctx,
    )
}

public(package) fun create_package_freeze_guardian_cap(
    registry_id: &mut UID,
    ctx: &mut TxContext
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    authority::new_multiton(
        registry_id,
        &PACKAGE {},
        &FREEZE_GUARDIAN {},
        this_package(),
        ctx,
    )
}

public(package) fun create_vendor_admin_cap<VendorKey>(
    registry_id: &mut UID,
): AuthorityCap<VENDOR<VendorKey>, ADMIN> {
    authority::new_admin_cap(registry_id, &VENDOR {}, this_package())
}

public(package) fun create_vendor_assistant_cap<VendorKey>(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    authority::new_multiton_assistant_cap(
        registry_id,
        &VENDOR {},
        this_package(),
        ctx,
    )
}

public(package) fun create_vendor_pause_guardian_cap<VendorKey>(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, PAUSE_GUARDIAN> {
    authority::new_multiton(
        registry_id,
        &VENDOR {},
        &PAUSE_GUARDIAN {},
        this_package(),
        ctx,
    )
}

public(package) fun create_vendor_maintenance_cap<VendorKey>(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, MAINTENANCE> {
    authority::new_multiton(
        registry_id,
        &VENDOR {},
        &MAINTENANCE {},
        this_package(),
        ctx,
    )
}

public(package) fun create_vendor_treasury_cap<VendorKey>(
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, TREASURY> {
    authority::new_multiton(
        registry_id,
        &VENDOR {},
        &TREASURY {},
        this_package(),
        ctx,
    )
}

public(package) fun create_account_admin_cap(
    account_uid: &mut UID,
    account_obj_id: ID,
): AuthorityCap<ACCOUNT, ADMIN> {
    authority::new_admin_cap(account_uid, &ACCOUNT {}, account_obj_id)
}

public(package) fun create_account_assistant_cap(
    cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry_id: &mut UID,
    ctx: &mut TxContext,
): AuthorityCap<ACCOUNT, ASSISTANT> {
    authority::new_multiton_assistant_cap(
        registry_id,
        &ACCOUNT {},
        cap.`for`(),
        ctx,
    )
}

public(package) fun destroy_account_assistant_cap(
    cap: AuthorityCap<ACCOUNT, ASSISTANT>,
) {
    cap.destroy(internal::permit<ACCOUNT>())
}

public fun assert_is_admin_or_assistant<Role>() {
    let role = type_name::with_defining_ids<Role>();
    let is_admin_or_assistant = role == type_name::with_defining_ids<ASSISTANT>()
        || role == type_name::with_defining_ids<ADMIN>();
    assert!(is_admin_or_assistant, EInvalidAuthorityRole)
}

public(package) fun assert_is_admin_or_assistant_or_maintenance<Role>() {
    let role = type_name::with_defining_ids<Role>();
    let is_allowed = role == type_name::with_defining_ids<MAINTENANCE>()
        || role == type_name::with_defining_ids<ASSISTANT>()
        || role == type_name::with_defining_ids<ADMIN>();
    assert!(is_allowed, EInvalidAuthorityRole)
}

public(package) fun assert_is_not_admin<Role>() {
    let role = type_name::with_defining_ids<Role>();
    assert!(role != type_name::with_defining_ids<ADMIN>(), EInvalidAuthorityRole)
}

/// The ID of this package's original (defining) address.
fun this_package(): ID {
    let package_address = type_name::with_defining_ids<PACKAGE>().address_string().into_bytes();
    object::id_from_address(address::from_ascii_bytes(&package_address))
}
