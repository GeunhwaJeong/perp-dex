// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The perpetuals fixture with this package's witness authorized as an extension.
#[test_only]
module perpetuals_orders::orders_test_support;

use haneul::test_scenario::{Self as ts, Scenario};
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t, Fx};
use perpetuals_orders::extension::ORDERS;

public fun setup(): (Scenario, Fx) {
    let (mut sc, fx) = t::setup();
    sc.next_tx(t::admin(&fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    registry.authorize_extension<ORDERS>(t::perp_admin(&fx));
    ts::return_shared(registry);
    (sc, fx)
}
