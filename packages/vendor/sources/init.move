// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module vendor::init;

use haneul::package;
use vendor::authority;
use vendor::config;

// === Types ===

public struct INIT has drop {}

// === Functions ===

fun init(witness: INIT, ctx: &mut TxContext) {
    let mut config = config::new(&witness, ctx);
    authority::create_package_admin_cap_and_keep(&witness, config.borrow_mut_id(), ctx);
    transfer::public_share_object(config);
    package::claim_and_keep(witness, ctx)
}
