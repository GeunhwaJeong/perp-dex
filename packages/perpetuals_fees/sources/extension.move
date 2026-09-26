// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The witness this package presents to the perpetuals `*_as_extension` entry points. Only
/// this package can create it; the perpetuals package admin authorizes the type once with
/// `registry::authorize_extension<FEES>`.
module perpetuals_fees::extension;

public struct FEES has drop {}

public(package) fun witness(): FEES {
    FEES {}
}
