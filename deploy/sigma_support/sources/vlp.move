// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// LP coin of the Sigma market-making vault over TUSD. A vault mints LP one unit per
/// collateral unit, so it has TUSD's 6 decimals.
module sigma_support::vlp;

use haneul::coin;

public struct VLP has drop {}

#[allow(deprecated_usage)]
fun init(otw: VLP, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        otw,
        6,
        b"VLP",
        b"Sigma Vault LP",
        b"LP coin of the Sigma market-making vault (TUSD shadow run)",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender())
}
