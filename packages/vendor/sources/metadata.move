// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module vendor::metadata;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::derived_object;
use haneul::dynamic_field;
use haneul::vec_map::{Self, VecMap};
use std::ascii::String;
use std::type_name;
use vendor::authority::VENDOR;
use vendor::config::Config;
use vendor::events;

// === Errors and constants ===

const EVendorMetadataAlreadyCreated: u64 = 0;
const ERestrictedKey: u64 = 1;

// === Types ===

public struct VendorMetadataKey<phantom VendorKey> has copy, drop, store {}

public struct ApprovedDomainRegistrationKey<phantom Domain> has copy, drop, store {}

public struct VendorMetadata<phantom VendorKey> has key, store {
    id: UID,
    name: String,
    description: String,
    extra_fields: VecMap<String, String>,
}

// === Functions ===

public fun new<VendorKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    name: String,
    description: String,
): VendorMetadata<VendorKey> {
    config.assert_package_version();
    config.assert_has_active_vendor_authority(cap);
    let key = VendorMetadataKey<VendorKey> {};
    let config_id = config.borrow_mut_id();
    assert!(!derived_object::exists(config_id, key), EVendorMetadataAlreadyCreated);
    VendorMetadata {
        id: derived_object::claim(config_id, key),
        name,
        description,
        extra_fields: vec_map::empty(),
    }
}

public fun set_name<VendorKey, ADMIN_OR_ASSISTANT>(
    metadata: &mut VendorMetadata<VendorKey>,
    config: &Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    name: String,
) {
    config.assert_package_version();
    config.assert_has_active_vendor_authority(cap);
    metadata.name = name
}

public fun set_description<VendorKey, ADMIN_OR_ASSISTANT>(
    metadata: &mut VendorMetadata<VendorKey>,
    config: &Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    description: String,
) {
    config.assert_package_version();
    config.assert_has_active_vendor_authority(cap);
    metadata.description = description
}

public fun set_extra_field<VendorKey, ADMIN_OR_ASSISTANT>(
    metadata: &mut VendorMetadata<VendorKey>,
    config: &Config,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    key: String,
    value: String,
) {
    config.assert_package_version();
    assert!(!config.is_restricted_key(&key), ERestrictedKey);
    config.assert_has_active_vendor_authority(cap);
    let extra_fields = &mut metadata.extra_fields;
    let fields = freeze(extra_fields);
    let lookup_key = key;
    if (!fields.contains(&lookup_key)) {
        extra_fields.insert(key, value)
    } else {
        let fields = extra_fields;
        let lookup_key = key;
        *fields.get_mut(&lookup_key) = value
    }
}

public fun approve_domain_registration<VendorKey, Domain>(
    metadata: &mut VendorMetadata<VendorKey>,
    config: &Config,
    _: &AuthorityCap<Domain, ADMIN>,
) {
    config.assert_package_version();
    dynamic_field::add(
        &mut metadata.id,
        ApprovedDomainRegistrationKey<Domain> {},
        true,
    );
    events::emit_approve_domain_registration_event(
        type_name::with_defining_ids<VendorKey>(),
        type_name::with_defining_ids<Domain>(),
    )
}

public fun revoke_domain_registration_approval<VendorKey, Domain>(
    metadata: &mut VendorMetadata<VendorKey>,
    config: &Config,
    _: &AuthorityCap<Domain, ADMIN>,
) {
    config.assert_package_version();
    let _: bool = dynamic_field::remove(
        &mut metadata.id,
        ApprovedDomainRegistrationKey<Domain> {},
    );
    events::emit_revoke_domain_registration_approval_event(
        type_name::with_defining_ids<VendorKey>(),
        type_name::with_defining_ids<Domain>(),
    )
}

public fun is_domain_registration_approved<VendorKey, Domain>(
    metadata: &VendorMetadata<VendorKey>,
): bool {
    dynamic_field::exists(
        &metadata.id,
        ApprovedDomainRegistrationKey<Domain> {},
    )
}
