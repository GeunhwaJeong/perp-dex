// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Liquidation, bad debt and auto-deleveraging on the `test_support` fixture.
///
/// Scenario: the maker rests 2 BTC at 100,000, the taker buys 1.9 BTC (190,000 notional on
/// 19,905 of collateral after the 95 fee, just inside 10x). The price then drops.
#[test_only]
module perpetuals::liquidation_tests;

use haneul::coin;
use perpetuals::adl;
use perpetuals::test_support::{Self as t, session, with_ch, with_market};
use perpetuals::tusd::TUSD;

const ASK: bool = true;
const BID: bool = false;

fun base(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }

/// The taker goes long 1.9 BTC at 100,000 against the maker.
fun open_levered_long(sc: &mut haneul::test_scenario::Scenario, fx: &t::Fx) {
    session!(sc, fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(2_000), t::px(100_000), 0, option::none(), false, option::none());
    });
    session!(sc, fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(1_900), false);
    });
}

/// Pushes the BTC price until the feed's 1 ms TWAP equals it exactly. Each update over `e` ms
/// shrinks the TWAP's distance to the price by a factor of `e + 1`, so four updates a quarter
/// of an hour apart take a 7,000 USD move down to zero at 18 decimals.
fun move_price(sc: &mut haneul::test_scenario::Scenario, fx: &mut t::Fx, dollars: u64) {
    let mut i = 0;
    while (i < 4) {
        t::set_price(sc, fx, dollars, 1_000_000);
        i = i + 1u64;
    }
}

fun liquidate(sc: &mut haneul::test_scenario::Scenario, fx: &t::Fx): perpetuals::clearing_house::SessionSummary {
    let liqee = t::account_id(fx, t::taker());
    session!(sc, fx, t::liquidator(), false, false, |hp| {
        hp.liquidate(liqee, &vector[]);
    })
}

// === Partial liquidation ===

#[test]
fun partial_liquidation_restores_the_initial_margin() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    // At 93,000 the position has 6,605 of equity against 8,835 of maintenance margin.
    move_price(&mut sc, &mut fx, 93_000);
    let summary = liquidate(&mut sc, &fx);
    // 1.4 BTC (the smallest lot-rounded size that restores 10x) is closed at the mark.
    assert!(summary.liquidated_size() == t::mbtc(1_400));
    assert!(summary.liquidation_mark_price_b9() == t::px(93_000));
    let (liquidated_base, liquidated_quote, is_long) = summary.liquidation_base_quote_and_side();
    assert!(liquidated_base == base(1_400) && liquidated_quote == t::usd(130_200) && is_long);
    assert!(summary.liquidation_bad_debt() == 0);
    with_ch!(&mut sc, &fx, |ch| {
        // Liqee: 0.5 BTC left; collateral 19,905 - 9,800 (pnl) - 1,302 (liquidation fee)
        // - 651 (insurance fee) = 8,152, which is 4,652 of margin against 4,650 required.
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(500) && quote == t::usd(50_000) && collateral == t::usd(8_152));
        // Liquidator: takes over the 1.4 BTC at 93,000 and earns the 1% fee.
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::liquidator()));
        assert!(base == base(1_400) && quote == t::usd(130_200) && collateral == t::usd(101_302));
        // The insurance fund earns 0.5% of the liquidated notional.
        let (_, insurance) = ch.collateral_and_insurance_fund_balances();
        assert!(insurance == 651 * t::tusd_unit());
        // Long open interest is unchanged: the liquidator holds what the liqee gave up.
        assert!(ch.market_state().open_interest() == base(1_900));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 38, location = perpetuals::clearing_house)]
fun healthy_positions_cannot_be_liquidated() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    // 98,000: 16,105 of equity against 9,310 of maintenance margin.
    move_price(&mut sc, &mut fx, 98_000);
    liquidate(&mut sc, &fx);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 8, location = perpetuals::clearing_house)]
fun self_liquidation_is_refused() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 93_000);
    let liqee = t::account_id(&fx, t::taker());
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.liquidate(liqee, &vector[]);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 5, location = perpetuals::clearing_house)]
fun liquidation_must_be_the_first_action() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 93_000);
    let liqee = t::account_id(&fx, t::taker());
    session!(&mut sc, &fx, t::liquidator(), false, false, |hp| {
        hp.place_limit_order(BID, t::mbtc(100), t::px(90_000), 0, option::none(), false, option::none());
        hp.liquidate(liqee, &vector[]);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 4, location = perpetuals::clearing_house)]
fun liquidation_must_cancel_the_liqees_orders() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    // The taker rests a far bid; the liquidator must pass its id. (A bid near the market would
    // move the book price and, through the premium TWAP, the mark.)
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_limit_order(BID, t::mbtc(10), t::px(50_000), 0, option::none(), false, option::none());
    });
    move_price(&mut sc, &mut fx, 93_000);
    liquidate(&mut sc, &fx);
    t::finish(sc, fx);
}

// === Bad debt ===

#[test, expected_failure(abort_code = 22, location = perpetuals::clearing_house)]
fun bad_debt_beyond_the_socialization_limit_aborts() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    // At 80,000 the position is 18,095 under water; the insurance fund is empty and the
    // fixture's market declares no socialization (max_bad_debt 0), so only ADL can close it.
    move_price(&mut sc, &mut fx, 80_000);
    liquidate(&mut sc, &fx);
    t::finish(sc, fx);
}

#[test]
fun bad_debt_is_paid_by_the_insurance_fund() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, _registry| {
        ch.donate_to_insurance_fund(coin::mint_for_testing<TUSD>(30_000 * t::tusd_unit(), sc.ctx()), sc.ctx());
    });
    move_price(&mut sc, &mut fx, 80_000);
    let summary = liquidate(&mut sc, &fx);
    // The whole 1.9 BTC closes at 80,000: -38,000 of pnl and 1,520 of liquidation fee leave
    // 19,615 of bad debt, which the fund covers. No insurance fee is charged on bad debt.
    assert!(summary.liquidated_size() == t::mbtc(1_900));
    assert!(summary.liquidation_bad_debt() == t::usd(19_615));
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == 0 && quote == 0 && collateral == 0);
        let (collateral, base, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::liquidator()));
        assert!(base == base(1_900) && collateral == t::usd(101_520));
        let (vault, insurance) = ch.collateral_and_insurance_fund_balances();
        assert!(insurance == (30_000 - 19_615) * t::tusd_unit());
        assert!(vault == (500_000 + 20_000 + 100_000 + 19_615) * t::tusd_unit());
        // Funding rates are untouched: nothing was socialized.
        let (long_rate, short_rate) = ch.market_state().cum_funding_rates();
        assert!(long_rate == 0 && short_rate == 0);
    });
    t::finish(sc, fx);
}

#[test]
fun uncovered_bad_debt_is_socialized_through_funding() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        // Allow up to 100,000 of bad debt to be socialized, with no cap on the margin drop.
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(), option::none(),
            option::some(t::usd(100_000)), option::some(t::one()),
        );
        ch.donate_to_insurance_fund(coin::mint_for_testing<TUSD>(10_000 * t::tusd_unit(), sc.ctx()), sc.ctx());
    });
    move_price(&mut sc, &mut fx, 80_000);
    liquidate(&mut sc, &fx);
    with_ch!(&mut sc, &fx, |ch| {
        // The fund pays its 10,000 and the remaining 9,615 is charged to the shorts through
        // the short cumulative funding rate: 9,615 / 1.9 of open interest per BTC.
        let (_, insurance) = ch.collateral_and_insurance_fund_balances();
        assert!(insurance == 0);
        let (long_rate, short_rate) = ch.market_state().cum_funding_rates();
        let per_base = ifixed::ifixed::div_up(t::usd(9_615), base(1_900));
        assert!(long_rate == 0 && short_rate == ifixed::ifixed::neg(per_base));
    });
    // The maker is short 1.9 BTC, so settling its funding charges it the whole 9,615.
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, tusd, _registry| {
        ch.settle_position_funding(tusd, t::account_id(&fx, t::maker()), t::clock(&fx));
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, _, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::maker()));
        let expected = t::usd(500_000) - t::usd(38) - t::usd(9_615);
        // Within one lot's worth of rounding (the per-base rate is rounded up).
        assert!(ifixed::ifixed::less_than_eq(ifixed::ifixed::abs(ifixed::ifixed::sub(collateral, expected)), 1_000_000));
    });
    t::finish(sc, fx);
}

// === Auto-deleveraging ===

fun adl_cap(sc: &mut haneul::test_scenario::Scenario, fx: &t::Fx): authority_cap::authority::AuthorityCap<perpetuals::authority::PACKAGE, perpetuals::authority::ADL> {
    sc.next_tx(t::admin(fx));
    let mut registry = sc.take_shared_by_id<perpetuals::registry::Registry>(t::registry_id(fx));
    let cap = registry.create_package_adl_cap(t::perp_admin(fx), sc.ctx());
    haneul::test_scenario::return_shared(registry);
    cap
}

#[test]
fun adl_closes_a_bad_debt_position_against_a_counterparty() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 80_000);
    let cap = adl_cap(&mut sc, &fx);
    let (liqee, counterparty) = (t::account_id(&fx, t::taker()), t::account_id(&fx, t::maker()));
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        adl::execute_adl(
            ch, &cap, registry, liqee, vector[], vector[counterparty], vector[t::mbtc(1_900)],
            vector[(t::one() as u64)], btc, tusd, t::clock(&fx),
        );
    });
    with_ch!(&mut sc, &fx, |ch| {
        // The liqee is closed and emptied.
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == 0 && quote == 0 && collateral == 0);
        // The maker's short closes at 80,000 (+38,000) and absorbs the liqee's -18,095.
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(base == 0 && quote == 0);
        assert!(collateral == t::usd(500_000) - t::usd(38) + t::usd(38_000) - t::usd(18_095));
        assert!(ch.market_state().open_interest() == 0);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test]
fun adl_leaves_solvent_positions_alone() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 95_000);
    let cap = adl_cap(&mut sc, &fx);
    let (liqee, counterparty) = (t::account_id(&fx, t::taker()), t::account_id(&fx, t::maker()));
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        adl::execute_adl(
            ch, &cap, registry, liqee, vector[], vector[counterparty], vector[t::mbtc(1_900)],
            vector[(t::one() as u64)], btc, tusd, t::clock(&fx),
        );
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(1_900));
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6002, location = perpetuals::adl)]
fun adl_counterparty_must_hold_the_opposite_side() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 80_000);
    let cap = adl_cap(&mut sc, &fx);
    // The liquidator is flat, not short.
    let (liqee, counterparty) = (t::account_id(&fx, t::taker()), t::account_id(&fx, t::liquidator()));
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        adl::execute_adl(
            ch, &cap, registry, liqee, vector[], vector[counterparty], vector[t::mbtc(1_900)],
            vector[(t::one() as u64)], btc, tusd, t::clock(&fx),
        );
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6003, location = perpetuals::adl)]
fun adl_sizes_must_close_the_whole_position() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 80_000);
    let cap = adl_cap(&mut sc, &fx);
    let (liqee, counterparty) = (t::account_id(&fx, t::taker()), t::account_id(&fx, t::maker()));
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        adl::execute_adl(
            ch, &cap, registry, liqee, vector[], vector[counterparty], vector[t::mbtc(1_000)],
            vector[(t::one() as u64)], btc, tusd, t::clock(&fx),
        );
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6004, location = perpetuals::adl)]
fun adl_weights_must_sum_to_one() {
    let (mut sc, mut fx) = t::setup();
    open_levered_long(&mut sc, &fx);
    move_price(&mut sc, &mut fx, 80_000);
    let cap = adl_cap(&mut sc, &fx);
    let (liqee, counterparty) = (t::account_id(&fx, t::taker()), t::account_id(&fx, t::maker()));
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        adl::execute_adl(
            ch, &cap, registry, liqee, vector[], vector[counterparty], vector[t::mbtc(1_900)],
            vector[((t::one() / 2) as u64)], btc, tusd, t::clock(&fx),
        );
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}
