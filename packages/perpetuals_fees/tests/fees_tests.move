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
use perpetuals_fees::fees;
use perpetuals_fees::fees_test_support::{Self as f, fees_session, fees_session_as, musd, uusd, pct, bps, neg};
use haneul::test_scenario::Scenario;
use perpetuals::test_support::Fx;

const ONE: u256 = 1_000_000_000_000_000_000;
const ASK: bool = true;
const BID: bool = false;
/// An account owner who stakes, and the API key it trades through.
const OWNER: address = @0xA11CE;
const BOT: address = @0xB07;

fun fraction(numerator: u256, denominator: u256): u256 { numerator * ONE / denominator }

/// Reads a market-side window through the shared clearing house.
macro fun with_market($sc: &mut Scenario, $fx: &Fx, $f: |&ClearingHouse<TUSD>|) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    $f(&clearing_house);
    ts::return_shared(clearing_house);
}

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

// === Tier address ===

#[test]
fun an_unregistered_account_is_priced_by_its_signer() {
    let (mut sc, fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, OWNER, 1_000 * f::haneul());
    assert!(f::tier_address_of(&mut sc, &fx, t::taker(), BOT) == BOT);
    // The owner's stake counts when the owner signs, and not when its bot does.
    f::refresh_as(&mut sc, &fx, &ffx, t::taker(), OWNER);
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5));
    f::refresh_as(&mut sc, &fx, &ffx, t::taker(), BOT);
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == ONE && maker == ONE);
    f::finish(sc, fx, ffx);
}

#[test]
fun a_registered_tier_address_prices_every_signer() {
    let (mut sc, fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, OWNER, 1_000 * f::haneul());
    f::set_tier_address(&mut sc, &fx, t::taker(), OWNER);
    assert!(f::tier_address_of(&mut sc, &fx, t::taker(), BOT) == OWNER);
    // The bot's refresh and session now read the owner's stake.
    f::refresh_as(&mut sc, &fx, &ffx, t::taker(), BOT);
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5) && maker == fraction(3, 5));
    t::ladder(&mut sc, &fx, 100_000);
    let before = f::collateral_of(&mut sc, &fx, t::taker());
    fees_session_as!(&mut sc, &fx, &ffx, t::taker(), BOT, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    // 0.05% of 10,000 less the owner's 40% discount, on a session the bot signed.
    assert!(before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(3_000));
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == fraction(3, 5));
    f::finish(sc, fx, ffx);
}

#[test]
fun the_tier_address_is_always_the_registering_signer() {
    let (mut sc, fx, ffx) = f::setup();
    f::stake(&mut sc, &fx, &ffx, OWNER, 1_000 * f::haneul());
    // A stranger holding the cap can only register itself, never the owner's stake.
    f::set_tier_address(&mut sc, &fx, t::taker(), BOT);
    assert!(f::tier_address_of(&mut sc, &fx, t::taker(), OWNER) == BOT);
    f::refresh_as(&mut sc, &fx, &ffx, t::taker(), OWNER);
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == ONE);
    // Registering again replaces the address; clearing returns to the signer.
    f::set_tier_address(&mut sc, &fx, t::taker(), OWNER);
    assert!(f::tier_address_of(&mut sc, &fx, t::taker(), BOT) == OWNER);
    f::clear_tier_address(&mut sc, &fx, t::taker());
    assert!(f::tier_address_of(&mut sc, &fx, t::taker(), BOT) == BOT);
    f::refresh_as(&mut sc, &fx, &ffx, t::taker(), BOT);
    let (taker, _) = f::multipliers_on_market(&mut sc, &fx, t::taker());
    assert!(taker == ONE);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 4000, location = perpetuals::account)]
fun a_foreign_cap_cannot_register_a_tier_address() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(OWNER);
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(fx.account_obj(t::taker()));
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    fees::set_tier_address(&mut account, fx.cap(t::maker()), &registry, sc.ctx());
    ts::return_shared(account);
    ts::return_shared(registry);
    f::finish(sc, fx, ffx);
}

#[test]
fun a_session_without_fills_records_nothing() {
    let (mut sc, fx, ffx) = f::setup();
    fees_session!(&mut sc, &fx, &ffx, t::maker(), |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(100_000), 0, option::none(), false, option::none());
    });
    assert!(f::volume_of(&mut sc, &fx, t::maker()) == 0);
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(taker == ONE && maker == ONE);
    f::finish(sc, fx, ffx);
}

// === Maker volume ===

#[test]
fun maker_fills_are_credited_on_the_market_and_swept_into_the_account() {
    let (mut sc, fx, ffx) = f::setup();
    t::ladder(&mut sc, &fx, 100_000);
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
    let maker_id = fx.account_id(t::maker());
    with_market!(&mut sc, &fx, |ch| {
        // Three fills: 0.1 at 100,000, 0.1 at 100,100 and 0.05 at 100,200.
        assert!(fees::unswept_maker_volume(ch, maker_id, 0) == t::usd(25_020));
        assert!(fees::maker_volume(ch, maker_id, 0) == t::usd(25_020));
        assert!(fees::market_maker_volume(ch, 0) == t::usd(25_020));
        assert!(fees::maker_share(ch, maker_id, 0) == ONE);
    });
    // Nothing reached the maker's account yet.
    assert!(f::volume_of(&mut sc, &fx, t::maker()) == 0);
    f::refresh(&mut sc, &fx, &ffx, t::maker());
    assert!(f::volume_of(&mut sc, &fx, t::maker()) == t::usd(25_020));
    with_market!(&mut sc, &fx, |ch| {
        assert!(fees::unswept_maker_volume(ch, maker_id, 0) == 0);
        assert!(fees::maker_volume(ch, maker_id, 0) == t::usd(25_020));
    });
    // The maker's volume tier is the second one, and its whole-market share earns the 0.002%
    // rebate: -0.00002 / 0.0002 = -0.1.
    let (taker, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(taker == fraction(4, 5) && maker == neg(fraction(1, 10)));
    f::finish(sc, fx, ffx);
}

#[test]
fun a_share_rebate_is_paid_out_of_the_takers_fee() {
    let (mut sc, fx, ffx) = f::setup();
    t::ladder(&mut sc, &fx, 100_000);
    // A first taker fill gives the maker the whole market's maker volume.
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    f::refresh(&mut sc, &fx, &ffx, t::maker());
    let (_, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(maker == neg(fraction(1, 10)));
    let maker_before = f::collateral_of(&mut sc, &fx, t::maker());
    let taker_before = f::collateral_of(&mut sc, &fx, t::taker());
    let fees_before = f::fees_accrued(&mut sc, &fx);
    // The next fill (0.1 at 100,100) rebates the maker 0.002% while the taker pays 0.05%.
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    assert!(f::collateral_of(&mut sc, &fx, t::maker()) - maker_before == uusd(200_200));
    assert!(taker_before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(5_005));
    assert!(f::fees_accrued(&mut sc, &fx) - fees_before == uusd(4_804_800));
    f::finish(sc, fx, ffx);
}

#[test]
fun a_rebate_is_capped_at_the_takers_discounted_fee() {
    let (mut sc, fx, ffx) = f::setup();
    // The core caps a maker rebate per fill: set the maker to the full -1 (a 0.02% rebate) and
    // the taker to a tenth of its rate (0.005%) directly, bypassing the schedule.
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    let expires = fx.clock().timestamp_ms() + 1_000_000;
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::maker()), ONE, neg(ONE), expires,
    );
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::taker()), ONE / 10, ONE, expires,
    );
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    t::ladder(&mut sc, &fx, 100_000);
    let maker_before = f::collateral_of(&mut sc, &fx, t::maker());
    let taker_before = f::collateral_of(&mut sc, &fx, t::taker());
    let fees_before = f::fees_accrued(&mut sc, &fx);
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    // 10,000 notional: the taker pays 0.5, the maker receives 0.5 instead of 2, fees net zero.
    assert!(taker_before - f::collateral_of(&mut sc, &fx, t::taker()) == musd(500));
    assert!(f::collateral_of(&mut sc, &fx, t::maker()) - maker_before == musd(500));
    assert!(f::fees_accrued(&mut sc, &fx) == fees_before);
    f::finish(sc, fx, ffx);
}

#[test]
fun a_whole_market_share_below_the_volume_floor_earns_no_rebate() {
    let (mut sc, fx, ffx) = f::setup();
    t::ladder(&mut sc, &fx, 100_000);
    // 0.04 BTC at 100,000: the maker is the whole market, on 4,000 of maker volume.
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(40), false);
    });
    f::refresh(&mut sc, &fx, &ffx, t::maker());
    let maker_id = fx.account_id(t::maker());
    with_market!(&mut sc, &fx, |ch| {
        assert!(fees::maker_share(ch, maker_id, 0) == ONE);
        assert!(fees::maker_volume(ch, maker_id, 0) == t::usd(4_000));
    });
    // Below the 5,000 floor the share is worth nothing: tier 0 maker rate, multiplier one.
    let (_, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(maker == ONE);
    // Another 0.05 BTC (5,000, all at 100,000) makes 9,000: past the first floor, short of
    // the second tier's 10,000.
    fees_session!(&mut sc, &fx, &ffx, t::taker(), |hp| {
        hp.place_market_order(BID, t::mbtc(50), false);
    });
    f::refresh(&mut sc, &fx, &ffx, t::maker());
    with_market!(&mut sc, &fx, |ch| {
        assert!(fees::maker_volume(ch, maker_id, 0) == t::usd(9_000));
    });
    let (_, maker) = f::multipliers_on_market(&mut sc, &fx, t::maker());
    assert!(maker == neg(fraction(5, 100)));
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
fun a_taker_multiplier_above_one_is_rejected() {
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

#[test, expected_failure(abort_code = 59, location = perpetuals::clearing_house)]
fun a_negative_taker_multiplier_is_rejected() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::taker()), neg(ONE / 2), ONE, 1,
    );
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 59, location = perpetuals::clearing_house)]
fun a_maker_multiplier_below_minus_one_is_rejected() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(), &registry, fx.account_id(t::taker()), ONE, neg(ONE + 1), 1,
    );
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    f::finish(sc, fx, ffx);
}

// === Schedule math ===

#[test]
fun multipliers_follow_volume_stake_and_share() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    let (taker, maker) = schedule.multipliers(0, 0, 0, 0);
    assert!(taker == ONE && maker == ONE);
    let (taker, maker) = schedule.multipliers(t::usd(100_000), 0, 0, 0);
    assert!(taker == fraction(3, 5) && maker == fraction(1, 2));
    let (taker, maker) = schedule.multipliers(t::usd(100_000), 10 * f::haneul(), 0, 0);
    // 0.03 less 5% over 0.05; 0.01 less 5% over 0.02.
    assert!(taker == fraction(57, 100) && maker == fraction(475, 1000));
    // Half the market's maker volume on 5,000 of one's own: the 0.001% rebate replaces the
    // maker rate, undiscounted.
    let (taker, maker) = schedule.multipliers(t::usd(100_000), 1_000 * f::haneul(), pct(50), t::usd(5_000));
    assert!(taker == fraction(36, 100) && maker == neg(fraction(5, 100)));
    let (_, maker) = schedule.multipliers(0, 0, pct(49), t::usd(100_000));
    assert!(maker == ONE);
    // The share alone is not enough: below the floor the tier's rate stays the maker rate.
    let (_, maker) = schedule.multipliers(0, 0, pct(90), t::usd(4_999));
    assert!(maker == ONE);
    // 90% of the market on 9,999 reaches the first tier's floor, not the second's.
    let (_, maker) = schedule.multipliers(0, 0, pct(90), t::usd(9_999));
    assert!(maker == neg(fraction(5, 100)));
    let (_, maker) = schedule.multipliers(0, 0, pct(90), t::usd(10_000));
    assert!(maker == neg(fraction(1, 10)));
    assert!(schedule.volume_tier_index(t::usd(19_999)) == 0);
    assert!(schedule.volume_tier_index(t::usd(20_000)) == 1);
    assert!(schedule.staking_tier_index(999 * f::haneul()) == 2);
    assert!(schedule.staking_discount(1_000 * f::haneul()) == pct(40));
    assert!(schedule.share_tier_index(pct(90), t::usd(10_000)) == 2);
    assert!(schedule.share_tier_index(pct(90), t::usd(9_999)) == 1);
    assert!(schedule.share_tier_index(pct(90), 0) == 0);
    let (min_share, min_maker_volume, maker_fee) = schedule.share_tiers()[1].share_tier_fields();
    assert!(min_share == pct(90) && min_maker_volume == t::usd(10_000) && maker_fee == neg(bps(1) / 5));
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
        vector[0], vector[bps(6)], vector[bps(2)], vector[], vector[], vector[], vector[], vector[], 1, 14,
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
        vector[], vector[], vector[], vector[], vector[], 1, 14,
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
        vector[1, 2], vector[pct(10), pct(5)], vector[], vector[], vector[], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 12, location = perpetuals_fees::config)]
fun a_rebate_larger_than_the_smallest_taker_fee_is_rejected() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    // Taker 0.05% less a 40% discount is 0.03%; a 0.031% rebate could outrun it.
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), bps(5),
        vector[0], vector[bps(5)], vector[bps(5)],
        vector[1], vector[pct(40)], vector[pct(50)], vector[0], vector[neg(bps(3) + bps(1) / 10)], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 13, location = perpetuals_fees::config)]
fun share_tier_volume_floors_must_not_shrink() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    // A higher share tier asking for less volume would break the tiers' prefix order.
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), bps(2),
        vector[0], vector[bps(5)], vector[bps(2)], vector[], vector[],
        vector[pct(50), pct(90)], vector[t::usd(10_000), t::usd(5_000)], vector[neg(bps(1) / 10), neg(bps(1) / 5)],
        1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}

#[test, expected_failure(abort_code = 14, location = perpetuals_fees::config)]
fun share_tiers_need_a_base_maker_fee() {
    let (mut sc, fx, ffx) = f::setup();
    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared_by_id<perpetuals_fees::config::FeeSchedule>(ffx.schedule_id());
    // With no base maker rate a rebate could never be expressed as a multiplier.
    schedule.set_schedule(
        ffx.schedule_cap(), bps(5), 0,
        vector[0], vector[bps(5)], vector[0], vector[], vector[],
        vector[pct(50)], vector[0], vector[neg(bps(1) / 10)], 1, 14,
    );
    ts::return_shared(schedule);
    f::finish(sc, fx, ffx);
}
