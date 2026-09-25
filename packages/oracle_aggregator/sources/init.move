// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::init;

use haneul::package;
use oracle_aggregator::authority;
use oracle_aggregator::config;

// === Types ===

public struct INIT has drop {}

// === Functions ===

fun init(witness: INIT, ctx: &mut TxContext) {
    let mut config = config::create_config(&witness, ctx);
    authority::create_package_admin_cap_and_keep(&witness, config.borrow_mut_id(), ctx);
    config.share();
    package::claim_and_keep(witness, ctx)
}
