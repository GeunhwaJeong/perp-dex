// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator_haneul_integration::init;

use haneul::package;

// === Types ===

public struct INIT has drop {}

// === Functions ===

fun init(otw: INIT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx)
}
