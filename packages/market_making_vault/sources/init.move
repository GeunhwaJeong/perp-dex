// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::init;

use haneul::package;
use market_making_vault::config;

// === Types ===

public struct INIT has drop {}

// === Functions ===

fun init(witness: INIT, ctx: &mut TxContext) {
    config::create_config_and_share(&witness, ctx);
    package::claim_and_keep(witness, ctx)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(INIT {}, ctx)
}
