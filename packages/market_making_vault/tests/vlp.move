// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Unit test vault LP coin. A vault mints LP one unit per collateral unit, so it has TUSD's six
/// decimals. The one-time witness is minted with `test_utils`.
#[test_only]
module market_making_vault::vlp;

public struct VLP has drop {}
