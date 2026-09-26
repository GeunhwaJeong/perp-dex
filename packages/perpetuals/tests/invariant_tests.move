// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// A pseudo-random sequence of price moves, resting and crossing orders, cancels,
/// deallocations and liquidations on the `test_support` fixture, with the market's accounting
/// identity checked after every step.
///
/// Move tests cannot catch an abort, so the generator only takes actions the engine is known to
/// accept: an order is placed only when the account clears the initial margin with it at any
/// mark within 1% of the index, a crossing order is sent only against a non-empty side, and a
/// position is liquidated only when it is below maintenance at every mark within that band. The
/// price is pulled back toward 100,000 so leverage stays bounded; the taker only ever buys, so
/// it builds a levered long, and a 10% shock every 25 steps and a 25% crash at step 99 make
/// liquidation part of the sequence, with the insurance fund there for any bad debt. The seed
/// is fixed: the sequence is the same on every run.
#[test_only]
module perpetuals::invariant_tests;

use haneul::coin;
use ifixed::ifixed;
use perpetuals::test_support::{Self as t, session, with_ch, with_market};
use perpetuals::tusd::TUSD;

const ASK: bool = true;
const BID: bool = false;
const STEPS: u64 = 120;
/// Ten TUSD units of rounding allowed between the vault and the positions' books.
const TOLERANCE: u256 = 10_000_000_000_000;

// === Pseudo-random numbers (xorshift64) ===

fun next(seed: &mut u64): u64 {
    let mut s = *seed;
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    *seed = s;
    s
}

fun below(seed: &mut u64, n: u64): u64 { next(seed) % n }

// === Margin checks at the edges of a 1% band around the index ===

fun band(price: u64): (u256, u256) {
    (t::usd(price) * 99 / 100, t::usd(price) * 101 / 100)
}

/// Whether the account still clears the initial margin at mark `mark` after an order of `size`
/// (in base, ifixed) on `side`: resting when `taker` is false, filled at `limit` when true. A
/// tenth of a percent of the notional is set aside for fees.
fun clears_initial_margin(
    collateral: u256, base: u256, quote: u256, asks: u256, bids: u256,
    side: bool, size: u256, limit: u256, taker: bool, mark: u256,
): bool {
    let notional = ifixed::mul(size, limit);
    let fee_buffer = notional / 1000;
    let (base, quote, asks, bids) = if (taker) {
        if (side == ASK) {
            (ifixed::sub(base, size), ifixed::sub(quote, notional), asks, bids)
        } else {
            (ifixed::add(base, size), ifixed::add(quote, notional), asks, bids)
        }
    } else if (side == ASK) {
        (base, quote, ifixed::add(asks, size), bids)
    } else {
        (base, quote, asks, ifixed::add(bids, size))
    };
    let margin = ifixed::sub(ifixed::add(ifixed::sub(collateral, fee_buffer), ifixed::mul(base, mark)), quote);
    let net = ifixed::max(ifixed::abs(ifixed::add(base, bids)), ifixed::abs(ifixed::sub(base, asks)));
    let required = ifixed::mul(ifixed::mul(net, mark), t::imr());
    ifixed::greater_than_eq(margin, required)
}

// === The run ===

#[test]
fun random_sessions_conserve_the_vault() {
    let (mut sc, mut fx) = t::setup();
    // The liquidator carries enough margin to absorb any position, and the insurance fund
    // covers bad debt from a shock, since the fixture's market does not socialize.
    with_market!(&mut sc, &fx, t::liquidator(), |ch, account, _btc, _tusd, registry| {
        let cap = fx.cap(t::liquidator());
        account.deposit_collateral(cap, registry, coin::mint_for_testing<TUSD>(2_000_000 * t::tusd_unit(), sc.ctx()));
        ch.allocate_collateral(cap, account, 2_000_000 * t::tusd_unit());
        ch.donate_to_insurance_fund(coin::mint_for_testing<TUSD>(100_000 * t::tusd_unit(), sc.ctx()), sc.ctx());
    });

    let mut seed = 0x9E37_79B9_7F4A_7C15u64;
    let mut price = 100_000u64;
    // The resting order ids of each account, in fixture order (maker, taker, liquidator).
    let mut orders: vector<vector<u128>> = vector[vector[], vector[], vector[]];
    let mut liquidations = 0u64;
    let mut fills = 0u64;
    let mut step = 0;
    while (step < STEPS) {
        // 1. The index moves: a pull toward 100,000, a random step, and a shock now and then.
        let crash = step == 99;
        let shock = step % 25 == 24;
        let delta = if (crash) 25_000 else if (shock) 8_000 + below(&mut seed, 4_000) else below(&mut seed, 800);
        let mut p = if (price > 100_000) price - (price - 100_000) / 10 else price + (100_000 - price) / 10;
        p = if (!crash && below(&mut seed, 2) == 0) p + delta else p - delta;
        t::set_price(&mut sc, &mut fx, p, 1_000 + below(&mut seed, 10_000));
        price = p;

        // 2. Anyone below maintenance at every mark in the band is liquidated by the
        // liquidator (or by the maker, when it is the liquidator itself).
        let (lo, hi) = band(price);
        let mut who = 0;
        while (who < 3) {
            let liqee = fx.account_id(who);
            let mut liquidatable = false;
            with_ch!(&mut sc, &fx, |ch| {
                let position = ch.position(liqee);
                let (base, _) = position.base_and_quote_amounts();
                let (margin_lo, min_lo) = position.compute_margin_and_requirement(t::one(), lo, t::mmr(), 0);
                let (margin_hi, min_hi) = position.compute_margin_and_requirement(t::one(), hi, t::mmr(), 0);
                liquidatable = base != 0
                    && ifixed::less_than(margin_lo, min_lo)
                    && ifixed::less_than(margin_hi, min_hi);
            });
            if (liquidatable) {
                let liqor = if (who == t::liquidator()) t::maker() else t::liquidator();
                let ids = *vector::borrow(&orders, who);
                session!(&mut sc, &fx, liqor, true, false, |hp| {
                    hp.liquidate(liqee, &ids);
                });
                *vector::borrow_mut(&mut orders, who) = vector[];
                liquidations = liquidations + 1;
            };
            who = who + 1;
        };

        // 3. One action by one account: an order that rests, one that crosses, or a cancel
        // (a deallocation when there is nothing to cancel).
        let who = below(&mut seed, 3);
        let account_id = fx.account_id(who);
        let side = if (who == t::taker() || below(&mut seed, 2) == 0) BID else ASK;
        let lots = 10 + below(&mut seed, 190);
        let size = ifixed::from_balance(t::mbtc(lots), 1_000_000_000);
        let kind = below(&mut seed, 3);
        if (kind == 2) {
            // Cancel everything the account rests, or free its idle collateral.
            let ids = *vector::borrow(&orders, who);
            if (!ids.is_empty()) {
                with_market!(&mut sc, &fx, who, |ch, account, _btc, _tusd, _registry| {
                    ch.try_cancel_orders(fx.cap(who), account, &ids);
                });
                *vector::borrow_mut(&mut orders, who) = vector[];
            } else {
                // Free what the position does not need, then put half of it back so the
                // account keeps trading: the vault is crossed in both directions.
                with_market!(&mut sc, &fx, who, |ch, account, btc, tusd, _registry| {
                    let freed = ch.deallocate_free_collateral(fx.cap(who), account, btc, tusd, fx.clock());
                    if (freed > 1) {
                        ch.allocate_collateral(fx.cap(who), account, freed / 2);
                    };
                });
            }
        } else {
            let taker = kind == 1;
            // A crossing order is priced at the other side's best, so it always fills or, when
            // that best is the account's own order, cancels it (either counts as activity); a
            // resting one sits 1 to 50 dollars off the index and may still cross a skewed book.
            let mut dollars = if (side == ASK) price + 1 + below(&mut seed, 50) else price - 1 - below(&mut seed, 50);
            let mut allowed = false;
            with_ch!(&mut sc, &fx, |ch| {
                let best = ch.best_price_u64(!side);
                if (taker) {
                    if (best.is_some()) dollars = best.destroy_some() / t::b9();
                };
                let limit = t::usd(dollars);
                let (collateral, base, quote, asks, bids, _) = t::position_of(ch, account_id);
                allowed = (!taker || best.is_some())
                    && clears_initial_margin(collateral, base, quote, asks, bids, side, size, limit, taker, lo)
                    && clears_initial_margin(collateral, base, quote, asks, bids, side, size, limit, taker, hi)
                    && (!taker || (
                        clears_initial_margin(collateral, base, quote, asks, bids, side, 0, limit, taker, lo)
                            && clears_initial_margin(collateral, base, quote, asks, bids, side, 0, limit, taker, hi)
                    ));
            });
            if (allowed) {
                let mut posted = option::none();
                // Order type 3 is immediate-or-cancel, 0 good-till-cancel.
                let order_type = if (taker) 3 else 0;
                let summary = session!(&mut sc, &fx, who, false, false, |hp| {
                    posted = hp.place_limit_order(side, t::mbtc(lots), t::px(dollars), order_type, option::none(), false, option::none());
                });
                if (posted.is_some()) {
                    vector::borrow_mut(&mut orders, who).push_back(posted.destroy_some());
                };
                if (summary.base_filled_ask() != 0 || summary.base_filled_bid() != 0) {
                    fills = fills + 1;
                };
            };
        };

        // 4. The identity: the vault's collateral backs every position's collateral, the
        // funding it has not settled yet, and its pnl at any price (net base is zero, so that
        // is minus the entry notional), plus the fees accrued.
        with_ch!(&mut sc, &fx, |ch| {
            let (long_rate, short_rate) = ch.market_state().cum_funding_rates();
            let mut books = 0;
            let mut net_base = 0;
            let mut i = 0;
            while (i < 3) {
                let position = ch.position(fx.account_id(i));
                let (base, quote) = position.base_and_quote_amounts();
                let funding = position.calculate_position_funding_internal(long_rate, short_rate);
                books = ifixed::add(books, ifixed::sub(ifixed::add(position.collateral(), funding), quote));
                net_base = ifixed::add(net_base, base);
                i = i + 1;
            };
            assert!(net_base == 0);
            books = ifixed::add(books, ch.market_state().fees_accrued());
            let (vault, _) = ch.collateral_and_insurance_fund_balances();
            let vault = ifixed::from_balance(vault, t::fixed_per_tusd());
            let diff = ifixed::abs(ifixed::sub(vault, books));
            assert!(ifixed::less_than_eq(diff, TOLERANCE));
        });
        step = step + 1;
    };
    // The sequence must have exercised both sides of the engine.
    assert!(fills > 0);
    assert!(liquidations > 0);
    t::finish(sc, fx);
}
