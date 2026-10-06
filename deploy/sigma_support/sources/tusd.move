// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Test collateral of the Sigma shadow run on mainnet: 6 decimals like a dollar stablecoin,
/// minted only by the treasury holder and worth nothing. The markets opened on it are
/// closed and settled before the RYUSD markets open.
module sigma_support::tusd;

use haneul::coin;

public struct TUSD has drop {}

#[allow(deprecated_usage)]
fun init(otw: TUSD, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        otw,
        6,
        b"TUSD",
        b"Sigma Test USD",
        b"Sigma shadow-run test collateral. No value.",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender())
}
