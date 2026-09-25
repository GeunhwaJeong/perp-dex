// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::source;

use authority_cap::authority::AuthorityCap;
use haneul::derived_object;
use oracle_aggregator::authority::{Self, PACKAGE, SourceCap};
use oracle_aggregator::config::Config;
use oracle_aggregator::events;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EInvalidVersion: vector<u8> =
    b"This integration package version cannot be used for the requested action.";

// === Types ===

public struct SourceObjectKey has copy, drop, store(u16)

public struct Source<phantom SourceKey> has key, store {
    id: UID,
    source_cap: SourceCap,
    version: u64,
}

// === Functions ===

public fun create<SourceKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    _: &SourceKey,
    version: u64,
): Source<SourceKey> {
    let source_cap = config.new_source_id<SourceKey, ADMIN_OR_ASSISTANT>(cap);
    let source_id = source_cap.source_id();
    let source = Source {
        id: derived_object::claim(config.borrow_mut_id(), SourceObjectKey(source_id)),
        source_cap,
        version,
    };
    events::emit_created_source(source_id, source.id.to_inner());
    source
}

public fun set_authorized<SourceKey, ADMIN_OR_ASSISTANT>(
    source: &mut Source<SourceKey>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    authorized: bool,
) {
    config.set_authorized(cap, &mut source.source_cap, authorized)
}

public fun upgrade_version<SourceKey, ADMIN_OR_ASSISTANT>(
    source: &mut Source<SourceKey>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    version: u64,
) {
    assert!(source.version < version, EInvalidVersion);
    config.assert_package_version();
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(cap);

    source.version = version;
    events::emit_upgraded_source_version(source.source_cap.source_id(), version)
}

public fun source_id<SourceKey>(source: &Source<SourceKey>): u16 {
    source.source_cap.source_id()
}

public fun version<SourceKey>(source: &Source<SourceKey>): u64 {
    source.version
}

public fun object_id<SourceKey>(source: &Source<SourceKey>): ID {
    source.id.to_inner()
}

public fun derived_id(
    config: &Config,
    source_id: u16,
): ID {
    object::id_from_address(
        derived_object::derive_address(config.id(), SourceObjectKey(source_id)),
    )
}

public fun child_exists<SourceKey, Key: copy + drop + store>(
    source: &Source<SourceKey>,
    key: Key,
): bool {
    derived_object::exists(&source.id, key)
}

public fun child_id<SourceKey, Key: copy + drop + store>(
    source: &Source<SourceKey>,
    key: Key,
): ID {
    object::id_from_address(derived_object::derive_address(source.id.to_inner(), key))
}

public fun borrow_source_cap<SourceKey: drop>(
    source: &Source<SourceKey>,
    _witness: SourceKey,
): &SourceCap {
    &source.source_cap
}

public fun borrow_mut_id<SourceKey: drop>(
    source: &mut Source<SourceKey>,
    _witness: SourceKey,
): &mut UID {
    &mut source.id
}

public fun assert_version<SourceKey>(
    source: &Source<SourceKey>,
    current_version: u64,
) {
    if (source.version > current_version) {
        abort EInvalidVersion
    }
}
