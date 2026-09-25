// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator_pyth_integration::source;

use authority_cap::authority::AuthorityCap;
use oracle_aggregator::{
    authority::{PACKAGE, SourceCap},
    config::Config,
    source::{Self as aggregator_source, Source},
};

// === Errors and constants ===

const CURRENT_VERSION: u64 = 1;

// === Types ===

public struct PYTH has drop {}

// === Functions ===

public fun create<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
): Source<PYTH> {
    aggregator_source::create(config, cap, &PYTH {}, CURRENT_VERSION)
}

public(package) fun source_cap(source: &Source<PYTH>): &SourceCap {
    source.borrow_source_cap(PYTH {})
}

public fun authorize<ADMIN_OR_ASSISTANT>(
    source: &mut Source<PYTH>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert_version(source);
    source.set_authorized(config, cap, true)
}

public fun deauthorize<ADMIN_OR_ASSISTANT>(
    source: &mut Source<PYTH>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    assert_version(source);
    source.set_authorized(config, cap, false)
}

public(package) fun assert_version(source: &Source<PYTH>) {
    aggregator_source::assert_version(source, CURRENT_VERSION)
}
