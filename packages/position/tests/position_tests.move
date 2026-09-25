// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `position`: fills, realized and unrealized pnl, funding settlement, margin and free
/// collateral, maker fill restoration, margin requirement checks and the bankruptcy price.
///
/// Values are 18-decimal fixed point. Prices are quoted in USD per unit of base, collateral in
/// collateral units, and `P` scales a plain number to fixed point.
#[test_only]
module position::position_tests;

use haneul::tx_context;
use ifixed::ifixed;
use position::position::{Self as pos, Position};

const P: u256 = 1_000_000_000_000_000_000;

fun f(x: u64): u256 { (x as u256) * P }
fun neg(x: u256): u256 { ifixed::neg(x) }
fun frac(n: u64, d: u64): u256 { ifixed::from_u64fraction(n, d) }

/// `Position` has no `drop`, so tests park it in an object sent to the zero address.
public struct Holder has key { id: UID, position: Position }

fun done(position: Position) {
    let ctx = &mut tx_context::dummy();
    transfer::transfer(Holder { id: object::new(ctx), position }, @0x0)
}

fun fresh(): Position {
    pos::create_position(0, 0)
}

/// A long of `base` at an average entry of `price`, funded with `collateral`.
fun long(base: u64, price: u64, collateral: u64): Position {
    let mut p = fresh();
    p.add_to_collateral(f(collateral));
    p.add_base_to_position(false, f(base), f(base * price));
    p
}

/// A short of `base` at an average entry of `price`, funded with `collateral`.
fun short(base: u64, price: u64, collateral: u64): Position {
    let mut p = fresh();
    p.add_to_collateral(f(collateral));
    p.add_base_to_position(true, f(base), f(base * price));
    p
}

fun assert_base_quote(p: &Position, base: u256, quote: u256) {
    let (b, q) = p.base_and_quote_amounts();
    assert!(b == base && q == quote);
}

// === Creation and collateral ===

#[test]
fun create_position_starts_flat_without_leverage() {
    let p = pos::create_position(f(3), neg(f(2)));
    assert!(p.collateral() == 0);
    assert_base_quote(&p, 0, 0);
    let (asks, bids) = p.pending_base_amounts_by_side();
    assert!(asks == 0 && bids == 0 && p.pending_order_count() == 0);
    let (fl, fs) = p.funding_rate_snapshots();
    assert!(fl == f(3) && fs == neg(f(2)));
    assert!(p.initial_margin_ratio() == P);
    assert!(p.is_long_or_flat());
    // The effective ratio is the stricter of the position's and the market's.
    assert!(p.effective_initial_margin_ratio(frac(1, 10)) == P);
    done(p);
}

#[test]
fun collateral_arithmetic() {
    let mut p = fresh();
    p.add_to_collateral(f(10));
    p.sub_from_collateral(f(25));
    assert!(p.collateral() == neg(f(15)));
    assert!(p.reset_collateral() == f(15));
    assert!(p.collateral() == 0);
    done(p);
}

#[test]
fun add_to_collateral_usd_converts_and_rounds_down() {
    let mut p = fresh();
    // +10 USD at a collateral price of 2 is +5 collateral.
    assert!(p.add_to_collateral_usd(f(10), f(2)) == f(5));
    // -10 USD is -5.
    assert!(p.add_to_collateral_usd(neg(f(10)), f(2)) == 0);
    // Rounding is toward negative infinity: +1/3 rounds down, -1/3 rounds away from zero.
    assert!(p.add_to_collateral_usd(f(1), f(3)) == 333_333_333_333_333_333);
    assert!(p.add_to_collateral_usd(neg(f(1)), f(3)) == neg(1));
    // Crossing zero in both directions.
    p.add_to_collateral(1);
    p.add_to_collateral_usd(neg(f(3)), P);
    assert!(p.collateral() == neg(f(3)));
    p.add_to_collateral_usd(f(5), P);
    assert!(p.collateral() == f(2));
    done(p);
}

// === Fills ===

#[test]
fun long_open_increase_reduce_close() {
    let mut p = fresh();
    let (pnl, base) = p.add_base_to_position(false, f(1), f(100));
    assert!(pnl == 0 && base == f(1));
    assert_base_quote(&p, f(1), f(100));
    let (pnl, base) = p.add_base_to_position(false, f(1), f(110));
    assert!(pnl == 0 && base == f(2));
    assert_base_quote(&p, f(2), f(210));
    // Selling half realizes half the notional: 120 - 105 = 15.
    let (pnl, base) = p.add_base_to_position(true, f(1), f(120));
    assert!(pnl == f(15) && base == f(1));
    assert_base_quote(&p, f(1), f(105));
    // Closing the rest below entry loses 15.
    let (pnl, base) = p.add_base_to_position(true, f(1), f(90));
    assert!(pnl == neg(f(15)) && base == 0);
    assert_base_quote(&p, 0, 0);
    done(p);
}

#[test]
fun long_reduce_rounds_closed_notional_up() {
    // 3 units at 100 total; selling one closes ceil(100 / 3) of notional.
    let mut p = fresh();
    p.add_base_to_position(false, f(3), f(100));
    let (pnl, _) = p.add_base_to_position(true, f(1), f(40));
    assert!(pnl == f(40) - 33_333_333_333_333_333_334);
    assert_base_quote(&p, f(2), f(100) - 33_333_333_333_333_333_334);
    done(p);
}

#[test]
fun long_flips_to_short() {
    let mut p = long(1, 100, 0);
    // Selling 3 at 110: the first unit closes the long (+10), the other two open a short.
    let (pnl, base) = p.add_base_to_position(true, f(3), f(330));
    assert!(pnl == f(10) && base == neg(f(2)));
    assert_base_quote(&p, neg(f(2)), neg(f(220)));
    assert!(!p.is_long_or_flat());
    done(p);
}

#[test]
fun short_open_increase_reduce_close() {
    let mut p = fresh();
    let (pnl, base) = p.add_base_to_position(true, f(2), f(200));
    assert!(pnl == 0 && base == neg(f(2)));
    assert_base_quote(&p, neg(f(2)), neg(f(200)));
    let (pnl, base) = p.add_base_to_position(true, f(1), f(90));
    assert!(pnl == 0 && base == neg(f(3)));
    assert_base_quote(&p, neg(f(3)), neg(f(290)));
    // Buying one back at 80 closes floor(290 / 3) of notional: 96.66 - 80 = 16.66 profit.
    let closed = 96_666_666_666_666_666_666;
    let (pnl, base) = p.add_base_to_position(false, f(1), f(80));
    assert!(pnl == closed - f(80) && base == neg(f(2)));
    assert_base_quote(&p, neg(f(2)), neg(f(290) - closed));
    // Closing the rest at a loss.
    let (pnl, base) = p.add_base_to_position(false, f(2), f(300));
    assert!(pnl == neg(f(300) - (f(290) - closed)) && base == 0);
    assert_base_quote(&p, 0, 0);
    done(p);
}

#[test]
fun short_flips_to_long() {
    let mut p = short(2, 100, 0);
    // Buying 5 at 110: two units close the short (-20), three open a long at 110.
    let (pnl, base) = p.add_base_to_position(false, f(5), f(550));
    assert!(pnl == neg(f(20)) && base == f(3));
    assert_base_quote(&p, f(3), f(330));
    done(p);
}

#[test]
fun taker_fills_settle_pnl_fees_and_open_interest() {
    let mut p = fresh();
    p.add_to_collateral(f(20));
    // Buy 1 at 100 with a 0.1% taker fee and a 0.05% integrator fee, collateral price 1.
    let (pnl, taker_fee, integrator_fee, oi) =
        p.apply_taker_fills_and_settle(P, 0, 0, f(1), f(100), frac(1, 1000), frac(5, 10000));
    assert!(pnl == 0 && taker_fee == frac(1, 10) && integrator_fee == frac(5, 100) && oi == f(1));
    assert!(p.collateral() == f(20) - frac(15, 100));
    assert_base_quote(&p, f(1), f(100));
    // Sell it at 110: +10 pnl, fee on the quote filled, long open interest drops by 1.
    let (pnl, taker_fee, integrator_fee, oi) =
        p.apply_taker_fills_and_settle(P, f(1), f(110), 0, 0, frac(1, 1000), 0);
    assert!(pnl == f(10) && taker_fee == frac(11, 100) && integrator_fee == 0 && oi == neg(f(1)));
    assert!(p.collateral() == f(20) - frac(15, 100) + f(10) - frac(11, 100));
    // A negative taker fee is a rebate credited to the collateral.
    let (_, taker_fee, _, oi) =
        p.apply_taker_fills_and_settle(P, f(1), f(100), 0, 0, neg(frac(1, 1000)), 0);
    assert!(taker_fee == neg(frac(1, 10)) && oi == 0);
    assert!(!p.is_long_or_flat());
    done(p);
}

#[test]
fun pending_amounts_and_orders() {
    let mut p = fresh();
    p.add_to_pending_amount(true, f(3));
    p.add_to_pending_amount(false, f(2));
    p.update_pending_orders(true, 2);
    let (asks, bids) = p.pending_base_amounts_by_side();
    assert!(asks == f(3) && bids == f(2) && p.pending_order_count() == 2);
    p.sub_from_pending_amount(true, f(1));
    p.update_pending_orders(false, 1);
    let (asks, _) = p.pending_base_amounts_by_side();
    assert!(asks == f(2) && p.pending_order_count() == 1);
    done(p);
}

// === Valuation ===

#[test]
fun unrealized_pnl_and_margin_requirement() {
    let mut p = long(2, 105, 0);
    assert!(p.unrealized_pnl(f(120)) == f(30));
    assert!(p.unrealized_pnl(f(100)) == neg(f(10)));
    // Pending orders count toward the requirement on the side that would grow the position.
    p.add_to_pending_amount(false, f(1));
    p.add_to_pending_amount(true, f(3));
    assert!(p.abs_net_base() == f(3));
    assert!(p.margin_requirement(f(120), frac(1, 10)) == f(36));
    let s = short(2, 100, 0);
    assert!(s.unrealized_pnl(f(90)) == f(20));
    assert!(s.abs_net_base() == f(2));
    done(p);
    done(s);
}

#[test]
fun free_collateral_ignores_unrealized_profit() {
    let mut p = long(1, 100, 20);
    p.update_pending_orders(true, 0);
    let mr = frac(1, 10);
    // At entry: 20 collateral, 10 required.
    assert!(p.compute_free_collateral(P, f(100), mr, 0) == f(10));
    // A loss reduces what can be withdrawn.
    assert!(p.compute_free_collateral(P, f(90), mr, 0) == f(1));
    // A profit does not increase it.
    assert!(p.compute_free_collateral(P, f(120), mr, 0) == f(8));
    // Below the requirement there is nothing free.
    assert!(p.compute_free_collateral(P, f(50), mr, 0) == 0);
    // A 20% haircut values the collateral at 16 USD and converts the surplus back at 0.8.
    assert!(p.compute_free_collateral(P, f(100), mr, frac(2, 10)) == frac(75, 10));
    // A collateral price of 2 halves the collateral units needed.
    assert!(p.compute_free_collateral(f(2), f(100), mr, 0) == f(15));
    done(p);
}

#[test]
fun free_collateral_of_a_flat_position_is_its_collateral() {
    let mut p = fresh();
    p.add_to_collateral(f(7));
    assert!(p.compute_free_collateral(P, f(100), P, 0) == f(7));
    let (margin, required, free) = p.compute_margin_and_free_collateral(P, f(100), P, 0);
    assert!(margin == f(7) && required == 0 && free == f(7));
    p.sub_from_collateral(f(10));
    assert!(p.compute_free_collateral(P, f(100), P, 0) == 0);
    done(p);
}

#[test]
fun margin_and_free_collateral_together() {
    let p = long(1, 100, 20);
    let mr = frac(1, 10);
    let (margin, required, free) = p.compute_margin_and_free_collateral(P, f(120), mr, 0);
    assert!(margin == f(40) && required == f(12) && free == f(8));
    let (margin, required, free) = p.compute_margin_and_free_collateral(P, f(90), mr, 0);
    assert!(margin == f(10) && required == f(9) && free == f(1));
    let (margin, required, free) = p.compute_margin_and_free_collateral(P, f(50), mr, 0);
    assert!(margin == neg(f(30)) && required == f(5) && free == 0);
    let (margin, required) = p.compute_margin_and_requirement(P, f(120), mr, 0);
    assert!(margin == f(40) && required == f(12));
    // The haircut only applies to positive collateral.
    let (margin, _) = p.compute_margin_and_requirement(P, f(100), mr, frac(2, 10));
    assert!(margin == f(16));
    done(p);
}

#[test]
fun margin_with_unsettled_funding() {
    let p = long(2, 100, 20);
    // A cumulative long rate of +1 per unit is 2 USD owed by the position.
    let (margin, required) = p.compute_margin_with_fundings(P, f(100), frac(1, 10), f(1), f(1), 0);
    assert!(margin == f(18) && required == f(20));
    assert!(p.compute_free_collateral_with_fundings(P, f(100), frac(1, 10), f(1), f(1), 0) == 0);
    assert!(
        p.compute_free_collateral_with_fundings(P, f(100), frac(1, 10), neg(f(1)), 0, 0) == f(2),
    );
    done(p);
}

// === Funding ===

#[test]
fun longs_pay_when_the_cumulative_rate_rises() {
    let mut p = long(2, 100, 10);
    assert!(p.calculate_position_funding_internal(frac(1, 100), 0) == neg(frac(2, 100)));
    let (changed, funding, collateral) = p.settle_position_funding(P, frac(1, 100), 0);
    assert!(changed && funding == neg(frac(2, 100)) && collateral == f(10) - frac(2, 100));
    assert!(p.collateral() == collateral);
    let (fl, fs) = p.funding_rate_snapshots();
    assert!(fl == frac(1, 100) && fs == 0);
    // Settling again at the same rates changes nothing.
    let (changed, funding, _) = p.settle_position_funding(P, frac(1, 100), 0);
    assert!(!changed && funding == 0);
    // A falling rate pays the long back.
    let (changed, funding, collateral) = p.settle_position_funding(P, 0, 0);
    assert!(changed && funding == frac(2, 100) && collateral == f(10));
    done(p);
}

#[test]
fun shorts_receive_when_the_cumulative_rate_rises() {
    let mut p = short(2, 100, 10);
    assert!(p.calculate_position_funding_internal(0, frac(1, 100)) == frac(2, 100));
    let (changed, funding, collateral) = p.settle_position_funding(P, 0, frac(1, 100));
    assert!(changed && funding == frac(2, 100) && collateral == f(10) + frac(2, 100));
    // The long rate moving does not affect a short, but the snapshot still advances.
    let (changed, funding, _) = p.settle_position_funding(P, f(5), frac(1, 100));
    assert!(changed && funding == 0);
    let (fl, _) = p.funding_rate_snapshots();
    assert!(fl == f(5));
    let (changed, funding, collateral) = p.settle_position_funding(P, f(5), neg(frac(1, 100)));
    assert!(changed && funding == neg(frac(4, 100)) && collateral == f(10) - frac(2, 100));
    done(p);
}

#[test]
fun funding_rounds_against_the_position() {
    // 1 unit long, rate +1 USD, collateral price 3: pays ceil(1 / 3) collateral.
    let mut p = long(1, 100, 1);
    let (_, funding, collateral) = p.settle_position_funding(f(3), f(1), 0);
    assert!(funding == neg(f(1)) && collateral == f(1) - 333_333_333_333_333_334);
    // Receiving rounds down.
    let mut s = short(1, 100, 1);
    let (_, funding, collateral) = s.settle_position_funding(f(3), 0, f(1));
    assert!(funding == f(1) && collateral == f(1) + 333_333_333_333_333_333);
    // A flat position accrues no funding but its snapshots move.
    let mut flat = fresh();
    let (changed, funding, _) = flat.settle_position_funding(P, f(1), f(1));
    assert!(changed && funding == 0);
    done(p);
    done(s);
    done(flat);
}

#[test]
fun unrealized_funding_formula() {
    assert!(pos::unrealized_funding(f(2), f(2), f(5)) == 0);
    assert!(pos::unrealized_funding(f(3), f(2), f(5)) == neg(f(5)));
    assert!(pos::unrealized_funding(f(1), f(2), f(5)) == f(5));
    assert!(pos::unrealized_funding(f(3), f(2), neg(f(5))) == f(5));
}

// === Maker fills ===

#[test]
fun maker_fill_is_applied_when_margin_covers_the_liquidation_fee() {
    let mut p = fresh();
    p.add_to_collateral(f(5));
    let (applied, pnl, base) = p.apply_maker_fill_or_restore_if_bad_debt(
        false, f(1), f(100), frac(1, 10), frac(1, 100), P, f(100), 0, option::none(),
    );
    assert!(applied && pnl == 0 && base == f(1));
    assert!(p.collateral() == f(5) - frac(1, 10));
    assert_base_quote(&p, f(1), f(100));
    done(p);
}

#[test]
fun maker_fill_is_restored_when_it_would_leave_bad_debt() {
    let mut p = fresh();
    p.add_to_collateral(frac(5, 10));
    // Margin after the fill would be 0.4 USD, below the 1 USD liquidation fee on the position.
    let (applied, pnl, base) = p.apply_maker_fill_or_restore_if_bad_debt(
        false, f(1), f(100), frac(1, 10), frac(1, 100), P, f(100), 0, option::none(),
    );
    assert!(!applied && pnl == 0 && base == 0);
    assert!(p.collateral() == frac(5, 10));
    assert_base_quote(&p, 0, 0);
    // Negative margin is restored too.
    let mut s = short(1, 100, 1);
    let (applied, _, base) = s.apply_maker_fill_or_restore_if_bad_debt(
        true, f(1), f(100), 0, 0, P, f(150), 0, option::none(),
    );
    assert!(!applied && base == neg(f(1)));
    assert_base_quote(&s, neg(f(1)), neg(f(100)));
    done(p);
    done(s);
}

#[test]
fun maker_fill_respects_the_open_interest_share() {
    let mut p = fresh();
    p.add_to_collateral(f(50));
    // Growing past the cap is refused.
    let (applied, _, _) = p.apply_maker_fill_or_restore_if_bad_debt(
        false, f(1), f(100), 0, 0, P, f(100), 0, option::some(frac(5, 10)),
    );
    assert!(!applied);
    assert_base_quote(&p, 0, 0);
    // Reducing a position above the cap is allowed.
    let mut l = long(2, 100, 50);
    let (applied, pnl, base) = l.apply_maker_fill_or_restore_if_bad_debt(
        true, f(1), f(100), 0, 0, P, f(100), 0, option::some(frac(5, 10)),
    );
    assert!(applied && pnl == 0 && base == f(1));
    done(p);
    done(l);
}

// === Margin requirement checks ===

#[test]
fun margin_requirements_pass_when_met_or_risk_reduced() {
    // Above the requirement.
    pos::ensure_margin_requirements(f(1), f(10), f(20), f(10), f(1), f(1));
    // Below, but the requirement shrank and the margin did not.
    pos::ensure_margin_requirements(f(5), f(10), f(5), f(8), f(2), f(1));
    // Margin dropped, requirement dropped more: the ratio improved (5/10 -> 4/6).
    pos::ensure_margin_requirements(f(5), f(10), f(4), f(6), f(2), f(1));
    // Closing entirely.
    pos::ensure_margin_requirements(f(5), f(10), f(4), 0, f(2), 0);
    // Opening from flat against a shrinking requirement is fine on the side check.
    pos::ensure_margin_requirements(f(5), f(10), f(5), f(9), 0, f(1));
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun margin_requirements_reject_opening_below_initial_margin() {
    pos::ensure_margin_requirements(f(5), 0, f(5), f(10), 0, f(1));
}

#[test, expected_failure(abort_code = 2002, location = position::position)]
fun margin_requirements_reject_negative_margin() {
    pos::ensure_margin_requirements(f(5), f(10), neg(f(1)), f(8), f(2), f(1));
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun margin_requirements_reject_growing_requirement() {
    pos::ensure_margin_requirements(f(5), f(10), f(5), f(11), f(1), f(2));
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun margin_requirements_reject_side_flip() {
    pos::ensure_margin_requirements(f(5), f(10), f(5), f(8), f(1), neg(f(1)));
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun margin_requirements_reject_worse_ratio() {
    // 5/10 -> 3/8.
    pos::ensure_margin_requirements(f(5), f(10), f(3), f(8), f(2), f(1));
}

#[test, expected_failure(abort_code = 2001, location = position::position)]
fun margin_requirements_reject_margin_drop_with_same_requirement() {
    pos::ensure_margin_requirements(f(5), f(10), f(4), f(10), f(2), f(2));
}

#[test]
fun position_initial_margin_ratio_bounds() {
    let mut p = fresh();
    p.set_initial_margin_ratio(frac(2, 10), frac(1, 10));
    assert!(p.initial_margin_ratio() == frac(2, 10));
    assert!(p.effective_initial_margin_ratio(frac(1, 10)) == frac(2, 10));
    assert!(p.effective_initial_margin_ratio(frac(3, 10)) == frac(3, 10));
    p.set_initial_margin_ratio(P, frac(1, 10));
    p.set_initial_margin_ratio(frac(1, 10), frac(1, 10));
    done(p);
}

#[test, expected_failure(abort_code = 2003, location = position::position)]
fun position_initial_margin_ratio_below_market_is_rejected() {
    let mut p = fresh();
    p.set_initial_margin_ratio(frac(5, 100), frac(1, 10));
    done(p);
}

#[test, expected_failure(abort_code = 2003, location = position::position)]
fun position_initial_margin_ratio_above_one_is_rejected() {
    let mut p = fresh();
    p.set_initial_margin_ratio(P + 1, frac(1, 10));
    done(p);
}

// === Bankruptcy price ===

#[test]
fun bankruptcy_price_for_longs_and_shorts() {
    // Long 1 at 100 with 20 collateral goes bankrupt at 80.
    let l = long(1, 100, 20);
    assert!(l.calculate_bankruptcy_price(P, 1_000_000_000) == 80_000_000_000);
    // Short 1 at 100 with 20 collateral goes bankrupt at 120.
    let s = short(1, 100, 20);
    assert!(s.calculate_bankruptcy_price(P, 1_000_000_000) == 120_000_000_000);
    // Collateral price 2 doubles the cushion: long bankrupt at 60.
    assert!(l.calculate_bankruptcy_price(f(2), 1_000_000_000) == 60_000_000_000);
    // A flat position has no bankruptcy price.
    let flat = fresh();
    assert!(flat.calculate_bankruptcy_price(P, 1) == 0);
    done(l);
    done(s);
    done(flat);
}

#[test]
fun bankruptcy_price_rounds_conservatively_to_the_tick() {
    // 3 units for 100 with no collateral: 33.333... per unit.
    let mut l3 = fresh();
    l3.add_base_to_position(false, f(3), f(100));
    // Longs round up to the next tick, shorts down.
    assert!(l3.calculate_bankruptcy_price(P, 1) == 33_333_333_334);
    assert!(l3.calculate_bankruptcy_price(P, 1_000_000) == 33_334_000_000);
    let mut s3 = fresh();
    s3.add_base_to_position(true, f(3), f(100));
    assert!(s3.calculate_bankruptcy_price(P, 1) == 33_333_333_333);
    assert!(s3.calculate_bankruptcy_price(P, 1_000_000) == 33_333_000_000);
    // A long so well funded that the price would be negative reports 0.
    let rich = long(1, 100, 500);
    assert!(rich.calculate_bankruptcy_price(P, 1_000_000_000) == 0);
    done(l3);
    done(s3);
    done(rich);
}
