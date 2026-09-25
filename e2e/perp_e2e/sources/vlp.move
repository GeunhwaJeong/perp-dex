// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Localnet-only vault LP coin. A vault mints LP one unit per collateral unit, so it has TUSD's
/// 6 decimals.
module perp_e2e::vlp;

use haneul::coin;

public struct VLP has drop {}

#[allow(deprecated_usage)]
fun init(otw: VLP, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        otw,
        6,
        b"VLP",
        b"E2E Vault LP",
        b"Localnet E2E vault LP coin",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender())
}
