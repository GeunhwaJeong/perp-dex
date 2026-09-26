// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module perpetuals_fees::fees_tests;

use haneul::test_scenario as ts;
use perpetuals::clearing_house::ClearingHouse;
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t};
use perpetuals::tusd::TUSD;
use perpetuals_fees::extension;
use perpetuals_fees::fees_test_support::{Self as f, fees_session, musd, pct, bps};

const ONE: u256 = 1_000_000_000_000_000_000;
const BID: bool = false;

fun fraction(numerator: u256, denominator: u256): u256 { numerator * ONE / denominator }

// === Sessions ===

#[test]
fun first_session_pays_full_fee_and_records_its_volume() {
    let (mut sc, fx, ffx) = f::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let before = f::collateral_of(&mut sc, &fx, t::taker());
    let summary = fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
    let (_, quote) = summary.filled_base_and_quote(BID);
    assert!(quote == t::usd(25_020));
    // No multiplier was cached before this session: taker fee 0.05% of 25,020 = 12.51.
    assert!(before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(12_510));
    assert!(f::volume_of(&mut sc, &fx, t::taker()) == t::usd(25_020));
    // 25,020 is in the second volume tier: taker 0.04/0.05, maker 0.015/0.02.
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(4, 5) && maker == fraction(3, 4));
    f::finish(sc, fx, ffx);
}

#[test]
fun second_session_pays_the_cached_tier() {
    let (mut sc, fx, ffx) = f::setup();
    t::ladder(&mut sc, &fx, 100_000);
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(200), false);
    });
    // 20,010 crosses the second tier; the maker's ask at 100,200 is next.
    let before = f::collateral_of(&mut sc, &fx, t::taker());
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    // 0.04% of 10,020 = 4.008 instead of 5.010.
    assert!(before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(4_008));
    assert!(f::volume_of(&mut sc, &fx, t::taker()) == t::usd(30_030));
    f::finish(sc, fx, ffx);
}

#[test]
fun staking_discount_stacks_on_the_volume_tier() {
    let (mut sc, fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, fx.admin(), 1_000 * f::haneul());
    t::ladder(&mut sc, &fx, 100_000);
    f::refresh(&mut sc, &fx, &ffx, t::taker());
    // Tier 0 rates with the 40% staking discount: 0.03/0.05 and 0.012/0.02.
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5) && maker == fraction(3, 5));
    let before = f::collateral_of(&mut sc, &fx, t::taker());
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    // 0.05% of 10,000, discounted 40% = 3.
    assert!(before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(3_000));
    f::finish(sc, fx, ffx);
}

#[test]
fun maker_multiplier_scales_the_maker_fee_on_the_takers_fill() {
    let (mut sc, fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, fx.admin(), 100 * f::haneul());
    f::refresh(&mut sc, &fx, &ffx, t::maker());
    let (_, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(maker == fraction(9, 10));
    t::ladder(&mut sc, &fx, 100_000);
    let before = f::collateral_of(&mut sc, &fx, t::maker());
    // The taker has no multiplier: it still pays 0.05% while the maker pays 0.02% less 10%.
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    assert!(before - f::collateral_of(&mut sc, &fx, t::maker()) == musd(1_800));
    f::finish(sc, fx, ffx);
}

#[test]
fun an_expired_multiplier_means_full_fees() {
    let (mut sc, mut fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, fx.admin(), 1_000 * f::haneul());
    f::refresh(&mut sc, &fx, &ffx, t::taker());
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5));
    // One day later the cache has lapsed.
    t::set_price(&mut sc, &mut fx, 100_000, 86_400_000);
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == ONE && maker == ONE);
    t::ladder(&mut sc, &fx, 100_000);
    let before = f::collateral_of(&mut sc, &fx, t::taker());
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    assert!(before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(5_000));
    // The session itself renewed the cache.
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5));
    f::finish(sc, fx, ffx);
}

#[test]
fun a_session_without_fills_records_nothing() {
    let (mut sc, fx, ffx) = f::setup();
    fees_session!(&mut sc, &fx, &ffx, t::maker(), |hp| {
        hp.place_limit_order(true, t::mbtc(100), t::px(100_000), 0, option::none(), false, option::none());
    });
    assert!(f::volume_of(&mut sc, &fx, t::maker()) == 0);
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(taker == ONE && maker == ONE);
    f::finish(sc, fx, ffx);
}

// === Core guard rails ===

#[test, expected_failure(abort_code = 5028, location = perpetuals::registry)]
fun an_unauthorized_extension_cannot_cache_multipliers() {
    let (mut sc, fx) = t::setup();
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::taker()), ONE / 2, ONE, 1,
    );
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 59, location = perpetuals::clearing_house)]
fun a_multiplier_above_one_is_rejected() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::taker()), ONE + 1, ONE, 1,
    );
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    f::finish(sc, fx, ffx);
}

// === Schedule math ===

#[test]
fun multipliers_follow_volume_and_stake() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    let (taker, maker) = schedule.multipliers(0, 0);
    assert!(taker == ONE && maker == ONE);
    let (taker, maker) = schedule.multipliers(t::usd(100_000), 0);
    assert!(taker == fraction(3, 5) && maker == fraction(1, 2));
    let (taker, maker) = schedule.multipliers(t::usd(100_000), 10 * f::haneul());
    // 0.03 less 5% over 0.05; 0.01 less 5% over 0.02.
    assert!(taker == fraction(57, 100) && maker == fraction(475, 1000));
    assert!(schedule.volume_tier_index(t::usd(19_999)) == 0);
    assert!(schedule.volume_tier_index(t::usd(20_000)) == 1);
    assert!(schedule.staking_tier_index(999 * f::haneul()) == 2);
    assert!(schedule.staking_discount(1_000 * f::haneul()) == pct(40));
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 6, location = perpetuals_fees::config)]
fun a_tier_fee_above_the_base_is_rejected() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), bps(2),
        vector[0], vector[bps(6)], vector[bps(2)], vector[], vector[], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 4, location = perpetuals_fees::config)]
fun volume_tiers_must_ascend() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), bps(2),
        vector[0, t::usd(10), t::usd(10)], vector[bps(5), bps(4), bps(3)], vector[bps(2), bps(2), bps(2)],
        vector[], vector[], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 7, location = perpetuals_fees::config)]
fun staking_discounts_must_not_shrink_with_stake() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), bps(2),
        vector[0], vector[bps(5)], vector[bps(2)],
        vector[1, 2], vector[pct(10), pct(5)], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}
