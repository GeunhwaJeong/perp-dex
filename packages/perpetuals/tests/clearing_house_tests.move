// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Matching engine and session tests on the fixture of `test_support`: resting orders, taker
/// fills across levels, order types, validation aborts, self-trade and expiry handling,
/// reduce-only clipping, pending order limits, margin checks and collateral movements.
///
/// The maker's ladder rests 0.1 BTC at 100,000 / 100,100 / 100,200 (asks) and 99,900 / 99,800 /
/// 99,700 (bids). Fees: maker 0.02%, taker 0.05%. Every account trades at 10x (IMR 10%).
#[test_only]
module perpetuals::clearing_house_tests;

use perpetuals::test_support::{Self as t, session, with_ch, with_account, with_market};

const ASK: bool = true;
const BID: bool = false;
const GTC: u64 = 0;
const FOK: u64 = 1;
const POST_ONLY: u64 = 2;
const IOC: u64 = 3;
const MAX_U64: u64 = 0xffff_ffff_ffff_ffff;

/// Thousandths of a dollar as an ifixed value.
fun musd(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }
/// BTC thousandths as an ifixed base amount.
fun base(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }
fun ask_id(dollars: u64, counter: u64): u128 { ((t::px(dollars) as u128) << 64) | (counter as u128) }
fun bid_id(dollars: u64, counter: u64): u128 {
    (((t::px(dollars) ^ MAX_U64) as u128) << 64) | (counter as u128)
}

/// A plain limit order at `dollars`.
fun limit(hp: &mut perpetuals::clearing_house::SessionHotPotato<perpetuals::tusd::TUSD>, side: bool, size: u64, dollars: u64, order_type: u64): Option<u128> {
    hp.place_limit_order(side, size, t::px(dollars), order_type, option::none(), false, option::none())
}

// === Fixture ===

#[test]
fun fixture_funds_three_accounts() {
    let (mut sc, fx) = t::setup();
    let (deposits, allocations) = (t::deposits(), t::allocations());
    let mut who = 0;
    while (who < 3) {
        with_account!(&mut sc, &fx, who, |account| {
            assert!(account.collateral_balance() == (deposits[who] - allocations[who]) * t::tusd_unit());
        });
        with_ch!(&mut sc, &fx, |ch| {
            let (collateral, base, quote, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, who));
            assert!(collateral == t::col(allocations[who] * t::tusd_unit()));
            assert!(base == 0 && quote == 0 && asks == 0 && bids == 0 && pending == 0);
            assert!(ch.position(t::account_id(&fx, who)).initial_margin_ratio() == t::imr());
        });
        who = who + 1;
    };
    with_ch!(&mut sc, &fx, |ch| {
        let (vault, insurance) = ch.collateral_and_insurance_fund_balances();
        assert!(vault == (500_000 + 20_000 + 100_000) * t::tusd_unit() && insurance == 0);
        assert!(ch.best_price_u64(ASK).is_none() && ch.best_price_u64(BID).is_none());
        assert!(ch.market_state().open_interest() == 0);
    });
    t::finish(sc, fx);
}

// === Resting orders and fills ===

#[test]
fun maker_ladder_rests_on_both_sides() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    with_ch!(&mut sc, &fx, |ch| {
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_000)));
        assert!(ch.best_price_u64(BID) == option::some(t::px(99_900)));
        assert!(ch.book_price() == option::some(musd(99_950_000)));
        let (collateral, base, _, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(collateral == t::col(500_000 * t::tusd_unit()) && base == 0);
        assert!(asks == base(300) && bids == base(300) && pending == 6);
        // Counters run in posting order: the three asks then the three bids.
        assert!(ch.orderbook().order_size(ask_id(100_000, 1)) == t::mbtc(100));
        assert!(ch.orderbook().order_size(bid_id(99_900, 4)) == t::mbtc(100));
        assert!(ch.market_state().open_interest() == 0);
    });
    t::finish(sc, fx);
}

#[test]
fun market_buy_walks_three_levels() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
    // 0.1 at 100,000 + 0.1 at 100,100 + 0.05 at 100,200 = 25,020 USD.
    assert!(summary.base_filled_bid() == base(250));
    let (filled_base, filled_quote) = summary.filled_base_and_quote(BID);
    assert!(filled_base == base(250) && filled_quote == t::usd(25_020));
    assert!(summary.execution_price(BID) == t::usd(100_080));
    assert!(summary.base_filled_ask() == 0 && summary.posted_orders() == 0);
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, base, quote, _, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        // Taker fee 0.05% of 25,020 = 12.51.
        assert!(collateral == t::col(20_000 * t::tusd_unit()) - musd(12_510));
        assert!(base == base(250) && quote == t::usd(25_020) && pending == 0);
        let (collateral, base, quote, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        // Maker fee 0.02% per fill: 2 + 2.002 + 1.002 = 5.004.
        assert!(collateral == t::col(500_000 * t::tusd_unit()) - musd(5_004));
        assert!(base == ifixed::ifixed::neg(base(250)) && quote == ifixed::ifixed::neg(t::usd(25_020)));
        assert!(asks == base(50) && bids == base(300) && pending == 4);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_200)));
        assert!(ch.orderbook().order_size(ask_id(100_200, 3)) == t::mbtc(50));
        // Only the long side counts as open interest; fees accrue in collateral units.
        assert!(ch.market_state().open_interest() == base(250));
        assert!(ch.market_state().fees_accrued() == musd(17_514));
    });
    t::finish(sc, fx);
}

#[test]
fun market_sell_hits_the_bids() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(ASK, t::mbtc(150), false);
    });
    // 0.1 at 99,900 + 0.05 at 99,800 = 14,980 USD.
    let (filled_base, filled_quote) = summary.filled_base_and_quote(ASK);
    assert!(filled_base == base(150) && filled_quote == t::usd(14_980));
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == ifixed::ifixed::neg(base(150)) && quote == ifixed::ifixed::neg(t::usd(14_980)));
        let (_, base, _, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(base == base(150) && asks == base(300) && bids == base(150) && pending == 5);
        assert!(ch.best_price_u64(BID) == option::some(t::px(99_800)));
        // The maker is the long here.
        assert!(ch.market_state().open_interest() == base(150));
    });
    t::finish(sc, fx);
}

#[test]
fun limit_order_fills_partially_and_rests_the_remainder() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        let id = limit(hp, BID, t::mbtc(150), 100_050, GTC);
        assert!(id == option::some(bid_id(100_050, 7)));
    });
    assert!(summary.base_filled_bid() == base(100) && summary.posted_orders() == 1);
    let (posted_asks, posted_bids) = summary.posted_base_by_side();
    assert!(posted_asks == 0 && posted_bids == base(50));
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(100) && asks == 0 && bids == base(50) && pending == 1);
        assert!(ch.best_price_u64(BID) == option::some(t::px(100_050)));
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_100)));
        assert!(ch.orderbook().order_size(bid_id(100_050, 7)) == t::mbtc(50));
    });
    t::finish(sc, fx);
}

#[test]
fun taker_then_maker_position_nets_out() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    // Sell it back into the bids: bought at 100,000, sold at 99,900, -10 pnl.
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(ASK, t::mbtc(100), false);
    });
    assert!(summary.base_filled_ask() == base(100));
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, base, quote, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == 0 && quote == 0);
        // Fees: 5 on the buy, 4.995 on the sell.
        assert!(collateral == t::col(20_000 * t::tusd_unit()) - t::usd(10) - musd(9_995));
        assert!(ch.market_state().open_interest() == 0);
    });
    t::finish(sc, fx);
}

// === Order types ===

#[test, expected_failure(abort_code = 46, location = perpetuals::clearing_house)]
fun fill_or_kill_aborts_when_not_filled() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        limit(hp, BID, t::mbtc(500), 100_200, FOK);
    });
    t::finish(sc, fx);
}

#[test]
fun fill_or_kill_fills_when_liquidity_suffices() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        let id = limit(hp, BID, t::mbtc(300), 100_200, FOK);
        assert!(id.is_none());
    });
    assert!(summary.base_filled_bid() == base(300) && summary.posted_orders() == 0);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 47, location = perpetuals::clearing_house)]
fun post_only_aborts_when_it_would_match() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        limit(hp, BID, t::mbtc(100), 100_000, POST_ONLY);
    });
    t::finish(sc, fx);
}

#[test]
fun post_only_rests_below_the_spread() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        let id = limit(hp, BID, t::mbtc(100), 99_950, POST_ONLY);
        assert!(id.is_some());
    });
    assert!(summary.base_filled_bid() == 0 && summary.posted_orders() == 1);
    with_ch!(&mut sc, &fx, |ch| assert!(ch.best_price_u64(BID) == option::some(t::px(99_950))));
    t::finish(sc, fx);
}

#[test]
fun immediate_or_cancel_never_rests() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        let id = limit(hp, BID, t::mbtc(500), 100_100, IOC);
        assert!(id.is_none());
    });
    assert!(summary.base_filled_bid() == base(200) && summary.posted_orders() == 0);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, bids, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(200) && bids == 0 && pending == 0);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_200)));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 44, location = perpetuals::clearing_house)]
fun unknown_order_type_aborts() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(100), 100_000, 4);
    });
    t::finish(sc, fx);
}

// === Validation ===

#[test, expected_failure(abort_code = 20, location = perpetuals::clearing_house)]
fun price_must_be_a_tick_multiple() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(100_000) + 1, GTC, option::none(), false, option::none());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 19, location = perpetuals::clearing_house)]
fun size_must_be_a_lot_multiple() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(100) + 1, 100_000, GTC);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 1, location = perpetuals::clearing_house)]
fun size_must_not_be_zero() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_market_order(BID, 0, false);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 3900, location = perpetuals::clearing_house)]
fun price_must_not_be_zero() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(100), 0, GTC);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 3, location = perpetuals::clearing_house)]
fun resting_order_must_meet_the_minimum_value() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::some(t::usd(1_000)),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(),
        );
    });
    // 0.005 BTC at a 100,000 mark is 500 USD.
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(5), 100_000, GTC);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 14, location = perpetuals::clearing_house)]
fun expiration_must_be_in_the_future() {
    let (mut sc, fx) = t::setup();
    let now = t::clock(&fx).timestamp_ms();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(100_000), GTC, option::none(), false, option::some(now));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 45, location = perpetuals::clearing_house)]
fun market_order_aborts_without_enough_liquidity() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(1_000), false);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 11, location = perpetuals::clearing_house)]
fun empty_session_aborts() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::taker(), false, false, |_hp| {});
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 1000, location = perpetuals::market)]
fun stale_oracle_aborts_the_session() {
    let (mut sc, mut fx) = t::setup();
    // The base feed tolerates 10 s of staleness.
    t::clock_mut(&mut fx).increment_for_testing(20_000);
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(100), 100_000, GTC);
    });
    t::finish(sc, fx);
}

// === Self-trade and expiry ===

#[test]
fun crossing_your_own_order_cancels_it_instead_of_filling() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let summary = session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, BID, t::mbtc(100), 100_000, GTC);
    });
    assert!(summary.base_filled_bid() == 0 && summary.posted_orders() == 1);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        // The crossed ask is gone, the bid rests: 2 asks and 4 bids.
        assert!(base == 0 && asks == base(200) && bids == base(400) && pending == 6);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_100)));
        assert!(ch.best_price_u64(BID) == option::some(t::px(100_000)));
        assert!(ch.orderbook().get_order(ask_id(100_000, 1)).is_none());
    });
    t::finish(sc, fx);
}

#[test]
fun expired_maker_orders_are_canceled_when_hit() {
    let (mut sc, mut fx) = t::setup();
    let expires = t::clock(&fx).timestamp_ms() + 1_000;
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(100_000), GTC, option::none(), false, option::some(expires));
        limit(hp, ASK, t::mbtc(100), 100_100, GTC);
    });
    t::set_price(&mut sc, &mut fx, 100_000, 2_000);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        limit(hp, BID, t::mbtc(100), 100_000, IOC);
    });
    assert!(summary.base_filled_bid() == 0);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, _, _, asks, _, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(asks == base(100) && pending == 1);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_100)));
    });
    t::finish(sc, fx);
}

// === Reduce-only ===

#[test, expected_failure(abort_code = 9, location = perpetuals::clearing_house)]
fun reduce_only_needs_a_position_to_reduce() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(101_000), GTC, option::none(), true, option::none());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 9, location = perpetuals::clearing_house)]
fun reduce_only_must_be_on_the_closing_side() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_limit_order(BID, t::mbtc(100), t::px(99_000), GTC, option::none(), true, option::none());
    });
    t::finish(sc, fx);
}

#[test]
fun reduce_only_orders_are_clipped_to_the_position() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        let id = hp.place_limit_order(ASK, t::mbtc(1_000), t::px(101_000), GTC, option::none(), true, option::none());
        assert!(id == option::some(ask_id(101_000, 7)));
    });
    let (posted_asks, _) = summary.posted_base_by_side();
    assert!(posted_asks == base(250));
    with_ch!(&mut sc, &fx, |ch| {
        assert!(ch.orderbook().order_size(ask_id(101_000, 7)) == t::mbtc(250));
        let (_, _, _, asks, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(asks == base(250) && pending == 1);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 51, location = perpetuals::clearing_house)]
fun a_session_takes_one_taker_side_only() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    // Buying and then selling as a taker in the same session is refused: taker fills are netted
    // per side at the end of the session.
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
        hp.place_market_order(ASK, t::mbtc(100), true);
    });
    t::finish(sc, fx);
}

// === Limits and margin ===

#[test, expected_failure(abort_code = 37, location = perpetuals::clearing_house)]
fun pending_order_limit_is_enforced_at_session_end() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::some(2),
            option::none(), option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(),
        );
    });
    t::ladder(&mut sc, &fx, 100_000);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun opening_beyond_the_initial_margin_aborts() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(3_000), 100_000, GTC);
    });
    // 2.5 BTC is 250,000 notional: 25,000 of initial margin against 19,875 of equity.
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(2_500), false);
    });
    t::finish(sc, fx);
}

#[test]
fun missing_margin_can_be_pulled_from_the_account() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(3_000), 100_000, GTC);
    });
    session!(&mut sc, &fx, t::taker(), true, false, |hp| {
        hp.place_market_order(BID, t::mbtc(2_500), false);
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, base, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        // Fee 125, then 5,125 pulled in to reach the 25,000 requirement.
        assert!(base == base(2_500) && collateral == t::col(25_000 * t::tusd_unit()));
        let (vault, _) = ch.collateral_and_insurance_fund_balances();
        // Fees stay in the vault as accrued fees, so it holds the deposits plus what was pulled.
        assert!(vault == (500_000 + 20_000 + 5_125 + 100_000) * t::tusd_unit());
    });
    with_account!(&mut sc, &fx, t::taker(), |account| {
        assert!(account.collateral_balance() == (80_000 - 5_125) * t::tusd_unit());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 30, location = perpetuals::clearing_house)]
fun missing_margin_beyond_the_account_balance_aborts() {
    let (mut sc, fx) = t::setup();
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        limit(hp, ASK, t::mbtc(6_000), 100_000, GTC);
        limit(hp, ASK, t::mbtc(6_000), 100_100, GTC);
    });
    // 10 BTC is 1,000,400 notional: 100,040 of margin against 19,499.8 of equity needs 80,540
    // from an account holding 80,000.
    session!(&mut sc, &fx, t::taker(), true, false, |hp| {
        hp.place_market_order(BID, t::mbtc(10_000), false);
    });
    t::finish(sc, fx);
}

#[test]
fun free_collateral_is_returned_at_session_end() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    // Buy 0.1 (10,000 notional, 1,000 required) and release everything above it.
    session!(&mut sc, &fx, t::taker(), false, true, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, _, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        // 20,000 - 5 fee = 19,995 equity, 1,000 stays as margin.
        assert!(collateral == t::col(1_000 * t::tusd_unit()));
    });
    with_account!(&mut sc, &fx, t::taker(), |account| {
        assert!(account.collateral_balance() == (80_000 + 18_995) * t::tusd_unit());
    });
    t::finish(sc, fx);
}

// === Cancels and collateral outside sessions ===

#[test]
fun users_cancel_their_own_orders() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    with_market!(&mut sc, &fx, t::maker(), |ch, account, _btc, _tusd, _registry| {
        ch.cancel_orders(t::cap(&fx, t::maker()), account, vector[ask_id(100_000, 1), bid_id(99_700, 6)]);
        let results = ch.try_cancel_orders(t::cap(&fx, t::maker()), account, &vector[ask_id(100_000, 1), ask_id(100_100, 2)]);
        assert!(results == vector[false, true]);
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (_, _, _, asks, bids, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(asks == base(100) && bids == base(200) && pending == 3);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_200)));
        assert!(ch.best_price_u64(BID) == option::some(t::px(99_900)));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 3000, location = perpetuals::orderbook)]
fun cancel_rejects_another_accounts_order() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    with_market!(&mut sc, &fx, t::taker(), |ch, account, _btc, _tusd, _registry| {
        ch.cancel_orders(t::cap(&fx, t::taker()), account, vector[ask_id(100_000, 1)]);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6, location = perpetuals::clearing_house)]
fun cancel_needs_at_least_one_order() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::taker(), |ch, account, _btc, _tusd, _registry| {
        ch.cancel_orders(t::cap(&fx, t::taker()), account, vector[]);
    });
    t::finish(sc, fx);
}

#[test]
fun deallocation_respects_the_margin_requirement() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
    with_market!(&mut sc, &fx, t::taker(), |ch, account, btc, tusd, _registry| {
        // Equity is 19,987.49 collateral minus the 20 of unrealized loss at the 100,000 mark
        // (the position was bought at 100,080 on average); 2,500 stays as margin.
        let out = ch.deallocate_collateral(t::cap(&fx, t::taker()), account, btc, tusd, 10_000 * t::tusd_unit(), t::clock(&fx));
        assert!(out == 10_000 * t::tusd_unit());
        let out = ch.deallocate_free_collateral(t::cap(&fx, t::taker()), account, btc, tusd, t::clock(&fx));
        assert!(out == 7_467_490_000);
        assert!(account.collateral_balance() == (80_000 + 10_000) * t::tusd_unit() + 7_467_490_000);
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, _, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(collateral == t::usd(2_520));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 40, location = perpetuals::clearing_house)]
fun deallocating_more_than_free_aborts() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::taker(), |ch, account, btc, tusd, _registry| {
        ch.deallocate_collateral(t::cap(&fx, t::taker()), account, btc, tusd, 20_001 * t::tusd_unit(), t::clock(&fx));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 4000, location = perpetuals::account)]
fun a_foreign_cap_cannot_trade_an_account() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::taker(), |ch, account, _btc, _tusd, _registry| {
        ch.allocate_collateral(t::cap(&fx, t::maker()), account, t::tusd_unit());
    });
    t::finish(sc, fx);
}
