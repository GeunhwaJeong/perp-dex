// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Localnet-only collateral coin (6 decimals, like USDC).
module perp_e2e::tusd;

use haneul::coin;

public struct TUSD has drop {}

#[allow(deprecated_usage)]
fun init(otw: TUSD, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        otw,
        6,
        b"TUSD",
        b"Test USD",
        b"Localnet E2E collateral",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender())
}
