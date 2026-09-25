// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

#[allow(deprecated_usage)]
module af_lp::af_lp;

use haneul::coin;
use haneul::url;

// === Errors and constants (original names from the published interface) ===

const SYMBOL: vector<u8> = b"afLP";
const NAME: vector<u8> = b"afLP";
const DESCRIPTION: vector<u8> = b"The LP Coin underpinning Aftermath's afLP Vault";
const URL: vector<u8> = b"https://aftermath.finance/coins/perpetuals/af-lp.svg";
const DECIMALS: u8 = 6;

// === Types ===

public struct AF_LP has drop {}

// === Functions ===

#[allow(deprecated_usage)]
fun init(otw: AF_LP, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        otw,
        DECIMALS,
        SYMBOL,
        NAME,
        DESCRIPTION,
        option::some(url::new_unsafe_from_bytes(URL)),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury_cap, ctx.sender())
}
