// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::events;

use haneul::event;
use std::string::String;
use std::type_name::TypeName;

// === Types ===

public struct CreatedPriceFeedStorage has copy, drop {
    price_feed_storage_obj_id: ID,
    storage_id: u32,
    symbol: String,
}

public struct CreatedSource has copy, drop { source_id: u16, source_object_id: ID }

public struct UpgradedSourceVersion has copy, drop { source_id: u16, version: u64 }

public struct AddedAuthorization has copy, drop { source_id: u16 }

public struct RemovedAuthorization has copy, drop { source_id: u16 }

public struct CreatedPriceFeed has copy, drop {
    storage_id: u32,
    source_id: u16,
    price: u128,
    timestamp_ms: u64,
}

public struct RemovedPriceFeed has copy, drop { storage_id: u32, source_id: u16 }

public struct UpdatedPriceFeed has copy, drop {
    storage_id: u32,
    source_id: u16,
    old_price: u128,
    old_timestamp_ms: u64,
    old_twap_price: u128,
    new_price: u128,
    new_timestamp_ms: u64,
    new_twap_price: u128,
}

public struct UpdatedTwapPeriodMs has copy, drop {
    storage_id: u32,
    source_id: u16,
    old_twap_period_ms: u64,
    new_twap_period_ms: u64,
}

public struct SetVendorRegistration has copy, drop { open: bool }

public struct RegisteredVendor has copy, drop { vendor_key: TypeName, vendor_admin_cap_id: ID }

public struct CreatedPackageRevokeVendorGuardianCap has copy, drop { cap_id: ID }

public struct GuardianRevokedVendorAuthorityCap has copy, drop {
    vendor_key: TypeName,
    role: TypeName,
    cap_id: ID,
}

public struct ReauthorizedVendorAdminCap has copy, drop { vendor_key: TypeName, cap_id: ID }

public struct CreatedPackageFreezeGuardianCap has copy, drop { cap_id: ID }

public struct Froze has copy, drop { id: ID, resume_version: u64, guardian_cap_id: ID }

public struct Unfroze has copy, drop { id: ID, version: u64 }

// === Functions ===

public(package) fun emit_created_price_feed_storage(
    price_feed_storage_obj_id: ID,
    storage_id: u32,
    symbol: String,
) {
    event::emit(CreatedPriceFeedStorage { price_feed_storage_obj_id, storage_id, symbol })
}

public(package) fun emit_created_source(
    source_id: u16,
    source_object_id: ID,
) {
    event::emit(CreatedSource { source_id, source_object_id })
}

public(package) fun emit_upgraded_source_version(
    source_id: u16,
    version: u64,
) {
    event::emit(UpgradedSourceVersion { source_id, version })
}

public(package) fun emit_added_authorization(source_id: u16) {
    event::emit(AddedAuthorization { source_id })
}

public(package) fun emit_removed_authorization(source_id: u16) {
    event::emit(RemovedAuthorization { source_id })
}

public(package) fun emit_created_price_feed(
    storage_id: u32,
    source_id: u16,
    price: u128,
    timestamp_ms: u64,
) {
    event::emit(CreatedPriceFeed { storage_id, source_id, price, timestamp_ms })
}

public(package) fun emit_removed_price_feed(
    storage_id: u32,
    source_id: u16,
) {
    event::emit(RemovedPriceFeed { storage_id, source_id })
}

public(package) fun emit_updated_price_feed(
    storage_id: u32,
    source_id: u16,
    old_price: u128,
    old_timestamp_ms: u64,
    old_twap_price: u128,
    new_price: u128,
    new_timestamp_ms: u64,
    new_twap_price: u128,
) {
    event::emit(UpdatedPriceFeed {
        storage_id,
        source_id,
        old_price,
        old_timestamp_ms,
        old_twap_price,
        new_price,
        new_timestamp_ms,
        new_twap_price,
    })
}

public(package) fun emit_updated_twap_period_ms(
    storage_id: u32,
    source_id: u16,
    old_twap_period_ms: u64,
    new_twap_period_ms: u64,
) {
    event::emit(UpdatedTwapPeriodMs {
        storage_id,
        source_id,
        old_twap_period_ms,
        new_twap_period_ms,
    })
}

public(package) fun emit_set_vendor_registration(open: bool) {
    event::emit(SetVendorRegistration { open })
}

public(package) fun emit_registered_vendor(vendor_key: TypeName, vendor_admin_cap_id: ID) {
    event::emit(RegisteredVendor { vendor_key, vendor_admin_cap_id })
}

public(package) fun emit_created_package_revoke_vendor_guardian_cap(cap_id: ID) {
    event::emit(CreatedPackageRevokeVendorGuardianCap { cap_id })
}

public(package) fun emit_guardian_revoked_vendor_authority_cap(
    vendor_key: TypeName,
    role: TypeName,
    cap_id: ID,
) {
    event::emit(GuardianRevokedVendorAuthorityCap { vendor_key, role, cap_id })
}

public(package) fun emit_reauthorized_vendor_admin_cap(vendor_key: TypeName, cap_id: ID) {
    event::emit(ReauthorizedVendorAdminCap { vendor_key, cap_id })
}

public(package) fun emit_created_package_freeze_guardian_cap(cap_id: ID) {
    event::emit(CreatedPackageFreezeGuardianCap { cap_id })
}

public(package) fun emit_froze(id: ID, resume_version: u64, guardian_cap_id: ID) {
    event::emit(Froze { id, resume_version, guardian_cap_id })
}

public(package) fun emit_unfroze(id: ID, version: u64) {
    event::emit(Unfroze { id, version })
}
