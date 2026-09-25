// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module vendor::events;

use haneul::event;
use std::ascii::String;
use std::type_name::TypeName;

// === Types ===

public struct Event<T: copy + drop> has copy, drop(T)

public struct ApproveDomainRegistrationEventV1 has copy, drop { vendor_key: String, domain: String }

public struct RevokeDomainRegistrationApprovalEventV1 has copy, drop {
    vendor_key: String,
    domain: String,
}

public struct CreatePackageRevokeVendorGuardianCapEventV1 has copy, drop { cap_id: ID }

public struct DeauthorizePackageRevokeVendorGuardianCapEventV1 has copy, drop { cap_id: ID }

public struct GuardianRevokeVendorAuthorityCapEventV1 has copy, drop {
    vendor_key: String,
    role: String,
    cap_id: ID,
}

public struct ReauthorizeVendorAdminCapEventV1 has copy, drop { vendor_key: String, cap_id: ID }

// === Functions ===

fun emit<VersionedEvent: copy + drop>(
    event: VersionedEvent
) {
    event::emit(Event(event))
}

public(package) fun emit_approve_domain_registration_event(
    vendor_key: TypeName,
    domain: TypeName,
) {
    emit(ApproveDomainRegistrationEventV1 {
        vendor_key: vendor_key.into_string(),
        domain: domain.into_string(),
    })
}

public(package) fun emit_revoke_domain_registration_approval_event(
    vendor_key: TypeName,
    domain: TypeName,
) {
    emit(RevokeDomainRegistrationApprovalEventV1 {
        vendor_key: vendor_key.into_string(),
        domain: domain.into_string(),
    })
}

public(package) fun emit_create_package_revoke_vendor_guardian_cap_event(cap_id: ID) {
    emit(CreatePackageRevokeVendorGuardianCapEventV1 { cap_id })
}

public(package) fun emit_deauthorize_package_revoke_vendor_guardian_cap_event(cap_id: ID) {
    emit(DeauthorizePackageRevokeVendorGuardianCapEventV1 { cap_id })
}

public(package) fun emit_guardian_revoke_vendor_authority_cap_event(
    vendor_key: TypeName,
    role: TypeName,
    cap_id: ID,
) {
    emit(GuardianRevokeVendorAuthorityCapEventV1 {
        vendor_key: vendor_key.into_string(),
        role: role.into_string(),
        cap_id,
    })
}

public(package) fun emit_reauthorize_vendor_admin_cap_event(
    vendor_key: TypeName,
    cap_id: ID,
) {
    emit(ReauthorizeVendorAdminCapEventV1 { vendor_key: vendor_key.into_string(), cap_id })
}
