// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::init;

use haneul::package;
use perpetuals::authority;
use perpetuals::registry;

// === Types ===

public struct INIT has drop {}

// === Functions ===

fun init(witness: INIT, ctx: &mut TxContext) {
    let mut registry = registry::create_registry(&witness, ctx);
    authority::create_package_admin_cap_and_keep(&witness, registry.borrow_mut_id(), ctx);
    registry.share();
    package::claim_and_keep(witness, ctx)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(INIT {}, ctx)
}
