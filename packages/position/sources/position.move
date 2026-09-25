// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module position::position;

use ifixed::ifixed;

// === Errors and constants (original names from the published interface) ===

macro fun initial_margin_requirement_violated(): u64 { 2001 }
macro fun position_bad_debt(): u64 { 2002 }
macro fun invalid_position_imr(): u64 { 2003 }

// === Types ===

public struct Position has store {
    collateral: u256,
    base_asset_amount: u256,
    quote_asset_notional_amount: u256,
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
    asks_quantity: u256,
    bids_quantity: u256,
    pending_orders: u64,
    initial_margin_ratio: u256,
}

// === Functions ===

// All amounts are ifixed values: signed 18-decimal fixed point in two's complement. Base amounts
// are positive for longs and negative for shorts, and the quote notional carries the sign of the
// base. Overflows abort with `ifixed`'s overflow code.

public fun create_position(
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
): Position {
    Position {
        cum_funding_rate_long: mkt_funding_rate_long,
        cum_funding_rate_short: mkt_funding_rate_short,
        collateral: 0,
        base_asset_amount: 0,
        quote_asset_notional_amount: 0,
        asks_quantity: 0,
        bids_quantity: 0,
        pending_orders: 0,
        initial_margin_ratio: 1_000_000_000_000_000_000,
    }
}

public fun is_long_or_flat(position: &Position): bool {
    !ifixed::is_neg(position.base_asset_amount)
}

public fun collateral(position: &Position): u256 {
    position.collateral
}

public fun base_and_quote_amounts(position: &Position): (u256, u256) {
    (position.base_asset_amount, position.quote_asset_notional_amount)
}

public fun pending_base_amounts_by_side(position: &Position): (u256, u256) {
    (position.asks_quantity, position.bids_quantity)
}

public fun funding_rate_snapshots(position: &Position): (u256, u256) {
    (position.cum_funding_rate_long, position.cum_funding_rate_short)
}

public fun pending_order_count(position: &Position): u64 {
    position.pending_orders
}

public fun initial_margin_ratio(position: &Position): u256 {
    position.initial_margin_ratio
}

public fun effective_initial_margin_ratio(position: &Position, market_imr: u256): u256 {
    ifixed::max(position.initial_margin_ratio, market_imr)
}

public fun add_to_collateral(position: &mut Position, fixed: u256) {
    position.collateral = ifixed::add(position.collateral, fixed)
}

public fun sub_from_collateral(position: &mut Position, fixed: u256) {
    position.collateral = ifixed::sub(position.collateral, fixed)
}

public fun reset_collateral(position: &mut Position): u256 {
    let collateral = position.collateral;
    position.collateral = 0;
    ifixed::abs(collateral)
}

/// Converts the USD amount into collateral units, rounding toward negative infinity, and adds it
/// to the collateral. Returns the new collateral.
public fun add_to_collateral_usd(
    position: &mut Position,
    fixed_usd: u256,
    collateral_price: u256
): u256 {
    let collateral_delta = ifixed::div(fixed_usd, collateral_price);
    position.collateral = ifixed::add(position.collateral, collateral_delta);
    position.collateral
}

// Applies a fill of `base_asset_delta` for `quote_asset_delta` (both positive) on side `side`
// (true for asks). Reducing a position realizes the pnl of the closed part, whose entry notional is
// taken pro rata from the position's notional; the rest of a fill that flips the position opens it
// on the other side. Returns the realized pnl and the new base amount.
public fun add_base_to_position(
    position: &mut Position,
    side: bool,
    base_asset_delta: u256,
    quote_asset_delta: u256,
): (u256, u256) {
    let is_ask = side;
    let base = position.base_asset_amount;
    let quote = position.quote_asset_notional_amount;
    let is_short = ifixed::is_neg(base);
    // The magnitudes of the position: base is signed by side, and the notional carries the
    // same sign as the base.
    let base_abs = ifixed::abs(base);
    let quote_abs = ifixed::abs(quote);

    if (is_ask == is_short) {
        // The fill grows the position on its own side (or opens it from flat).
        let new_base_abs = ifixed::add(base_abs, base_asset_delta);
        let new_quote_abs = ifixed::add(quote_abs, quote_asset_delta);
        position.base_asset_amount = if (is_short) ifixed::neg(new_base_abs) else new_base_abs;
        position.quote_asset_notional_amount =
            if (is_short) ifixed::neg(new_quote_abs) else new_quote_abs;
        return (0, position.base_asset_amount)
    };

    if (base_asset_delta <= base_abs) {
        // The fill reduces the position. The closed part of the notional is taken pro rata,
        // rounded so that the realized pnl never favors the position: up when closing a long
        // (the fill's proceeds are compared against a larger cost), down when closing a short.
        let closed_quote = if (is_short) mul_div(quote_abs, base_asset_delta, base_abs)
        else mul_div_up(quote_abs, base_asset_delta, base_abs);
        let remaining_base_abs = base_abs - base_asset_delta;
        let remaining_quote_abs = quote_abs - closed_quote;
        position.base_asset_amount =
            if (is_short) ifixed::neg(remaining_base_abs) else remaining_base_abs;
        position.quote_asset_notional_amount =
            if (is_short) ifixed::neg(remaining_quote_abs) else remaining_quote_abs;
        // A long is sold for the fill's quote and bought back for the closed notional.
        let pnl = if (is_short) ifixed::sub(closed_quote, quote_asset_delta)
        else ifixed::sub(quote_asset_delta, closed_quote);
        return (pnl, position.base_asset_amount)
    };

    // The fill closes the whole position and opens one on the other side with the rest. The
    // closing part of the fill's quote is pro rata as well, rounded against the position.
    let closing_quote = if (is_short) mul_div_up(quote_asset_delta, base_abs, base_asset_delta)
    else mul_div(quote_asset_delta, base_abs, base_asset_delta);
    let pnl = if (is_short) ifixed::sub(quote_abs, closing_quote)
    else ifixed::sub(closing_quote, quote_abs);
    let opened_base_abs = base_asset_delta - base_abs;
    let opened_quote_abs = quote_asset_delta - closing_quote;
    // The new position is on the side the fill was on: a sale opens a short.
    position.base_asset_amount = if (is_ask) ifixed::neg(opened_base_abs) else opened_base_abs;
    position.quote_asset_notional_amount =
        if (is_ask) ifixed::neg(opened_quote_abs) else opened_quote_abs;
    (pnl, position.base_asset_amount)
}

/// `a * b / c` on magnitudes, rounded down, with a single rounding step.
fun mul_div(a: u256, b: u256, c: u256): u256 {
    a * b / c
}

/// `a * b / c` on magnitudes, rounded up, with a single rounding step.
fun mul_div_up(a: u256, b: u256, c: u256): u256 {
    (a * b + c - 1) / c
}

public fun apply_taker_fills_and_settle(
    position: &mut Position,
    collateral_price: u256,
    base_filled_ask: u256,
    quote_filled_ask: u256,
    base_filled_bid: u256,
    quote_filled_bid: u256,
    taker_fee: u256,
    integrator_fee: u256,
): (u256, u256, u256, u256) {
    let base_before = position.base_asset_amount;
    let mut ask_pnl;
    let mut base_now;
    if (base_filled_ask != 0) {
        (ask_pnl, base_now) =
            add_base_to_position(position, true, base_filled_ask, quote_filled_ask);
    } else {
        ask_pnl = 0;
        base_now = base_before;
    };
    let mut bid_pnl;
    if (base_filled_bid != 0) {
        (bid_pnl, base_now) =
            add_base_to_position(position, false, base_filled_bid, quote_filled_bid);
    } else {
        bid_pnl = 0;
    };
    // Only long exposure counts toward open interest.
    let open_interest_delta =
        ifixed::sub(ifixed::max(base_now, 0), ifixed::max(base_before, 0));
    let pnl = ifixed::add(ask_pnl, bid_pnl);
    let quote_filled = quote_filled_ask + quote_filled_bid;
    // Fee amounts are rounded toward zero; a negative taker fee is a rebate.
    let taker_fee_amount = ifixed::mul_toward_zero(taker_fee, quote_filled);
    let integrator_fee_amount = ifixed::mul_toward_zero(integrator_fee, quote_filled);
    let collateral_change =
        ifixed::sub(pnl, ifixed::add(taker_fee_amount, integrator_fee_amount));
    let _ = add_to_collateral_usd(position, collateral_change, collateral_price);
    (pnl, taker_fee_amount, integrator_fee_amount, open_interest_delta)
}

public fun add_to_pending_amount(
    position: &mut Position,
    side: bool,
    fixed_value: u256
) {
    if (side) {
        position.asks_quantity = ifixed::add(position.asks_quantity, fixed_value)
    } else {
        position.bids_quantity = ifixed::add(position.bids_quantity, fixed_value)
    }
}

public fun sub_from_pending_amount(
    position: &mut Position,
    side: bool,
    fixed_value: u256
) {
    if (side) {
        position.asks_quantity = ifixed::sub(position.asks_quantity, fixed_value)
    } else {
        position.bids_quantity = ifixed::sub(position.bids_quantity, fixed_value)
    }
}

public fun update_pending_orders(
    position: &mut Position,
    to_add: bool,
    pending_orders: u64
) {
    if (to_add) {
        position.pending_orders = position.pending_orders + pending_orders
    } else {
        position.pending_orders = position.pending_orders - pending_orders
    }
}

public fun set_initial_margin_ratio(
    position: &mut Position,
    initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
) {
    assert!(
        ifixed::greater_than_eq(initial_margin_ratio, market_initial_margin_ratio)
            && ifixed::less_than_eq(initial_margin_ratio, 1_000_000_000_000_000_000),
        invalid_position_imr!(),
    );
    position.initial_margin_ratio = initial_margin_ratio
}

public fun compute_free_collateral_with_fundings(
    position: &Position,
    collateral_price: u256,
    mark_price: u256,
    margin_ratio: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
    collateral_haircut: u256,
): u256 {
    if (position.pending_orders == 0 && position.base_asset_amount == 0) {
        return ifixed::max(0, position.collateral)
    };
    let funding = calculate_position_funding_internal(
        position,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
    );
    let pnl = unrealized_pnl(position, mark_price);
    let required_margin = margin_requirement(position, mark_price, margin_ratio);
    let collateral_value = effective_collateral_usd_value_with_funding(
        position,
        collateral_price,
        collateral_haircut,
        funding,
    );
    // Unrealized profits cannot be withdrawn: only losses count toward the margin here.
    let margin =
        if (ifixed::less_than(pnl, 0)) ifixed::add(collateral_value, pnl) else collateral_value;
    if (ifixed::greater_than_eq(margin, required_margin)) {
        let free_collateral = ifixed::div(ifixed::sub(margin, required_margin), collateral_price);
        if (collateral_haircut != 0) {
            ifixed::div(free_collateral, ifixed::sub(1_000_000_000_000_000_000, collateral_haircut))
        } else {
            free_collateral
        }
    } else {
        0
    }
}

public fun compute_free_collateral(
    position: &Position,
    collateral_price: u256,
    mark_price: u256,
    margin_ratio: u256,
    collateral_haircut: u256
): u256 {
    if (position.pending_orders == 0 && position.base_asset_amount == 0) {
        return ifixed::max(0, position.collateral)
    };
    let pnl = unrealized_pnl(position, mark_price);
    let required_margin = margin_requirement(position, mark_price, margin_ratio);
    let collateral_value =
        effective_collateral_usd_value(position, collateral_price, collateral_haircut);
    // Unrealized profits cannot be withdrawn: only losses count toward the margin here.
    let margin =
        if (ifixed::less_than(pnl, 0)) ifixed::add(collateral_value, pnl) else collateral_value;
    if (ifixed::greater_than_eq(margin, required_margin)) {
        let free_collateral = ifixed::div(ifixed::sub(margin, required_margin), collateral_price);
        if (collateral_haircut != 0) {
            ifixed::div(free_collateral, ifixed::sub(1_000_000_000_000_000_000, collateral_haircut))
        } else {
            free_collateral
        }
    } else {
        0
    }
}

public fun compute_margin_and_free_collateral(
    position: &Position,
    collateral_price: u256,
    mark_price: u256,
    margin_ratio: u256,
    collateral_haircut: u256
): (u256, u256, u256) {
    if (position.pending_orders == 0 && position.base_asset_amount == 0) {
        let collateral = position.collateral;
        return (
            effective_collateral_usd_value(position, collateral_price, collateral_haircut),
            0,
            ifixed::max(0, collateral),
        )
    };
    let pnl = unrealized_pnl(position, mark_price);
    let required_margin = margin_requirement(position, mark_price, margin_ratio);
    let collateral_value =
        effective_collateral_usd_value(position, collateral_price, collateral_haircut);
    let margin = ifixed::add(collateral_value, pnl);
    if (ifixed::greater_than(required_margin, margin)) {
        return (margin, required_margin, 0)
    };
    // Unrealized profits cannot be withdrawn: only losses count toward the free collateral.
    let withdrawable_margin = if (ifixed::less_than(pnl, 0)) margin else collateral_value;
    let free_collateral = if (ifixed::greater_than_eq(withdrawable_margin, required_margin)) {
        let free_collateral =
            ifixed::div(ifixed::sub(withdrawable_margin, required_margin), collateral_price);
        if (collateral_haircut != 0) {
            ifixed::div(free_collateral, ifixed::sub(1_000_000_000_000_000_000, collateral_haircut))
        } else {
            free_collateral
        }
    } else {
        0
    };
    (margin, required_margin, free_collateral)
}

public fun compute_margin_with_fundings(
    position: &Position,
    collateral_price: u256,
    mark_price: u256,
    margin_ratio: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
    collateral_haircut: u256,
): (u256, u256) {
    let funding = calculate_position_funding_internal(
        position,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
    );
    let pnl = unrealized_pnl(position, mark_price);
    let required_margin = margin_requirement(position, mark_price, margin_ratio);
    let collateral_value = effective_collateral_usd_value_with_funding(
        position,
        collateral_price,
        collateral_haircut,
        funding,
    );
    (ifixed::add(collateral_value, pnl), required_margin)
}

public fun compute_margin_and_requirement(
    position: &Position,
    collateral_price: u256,
    mark_price: u256,
    margin_ratio: u256,
    collateral_haircut: u256
): (u256, u256) {
    let pnl = unrealized_pnl(position, mark_price);
    let required_margin = margin_requirement(position, mark_price, margin_ratio);
    (
        ifixed::add(
            effective_collateral_usd_value(position, collateral_price, collateral_haircut),
            pnl,
        ),
        required_margin,
    )
}

public fun apply_maker_fill_or_restore_if_bad_debt(
    position: &mut Position,
    order_is_ask: bool,
    base_asset_delta: u256,
    quote_asset_delta: u256,
    fees: u256,
    liquidation_fee: u256,
    collateral_price: u256,
    mark_price: u256,
    collateral_haircut: u256,
    max_maker_abs_base: Option<u256>,
): (bool, u256, u256) {
    let collateral_before = position.collateral;
    let base_before = position.base_asset_amount;
    let quote_before = position.quote_asset_notional_amount;
    let (pnl, base_now) =
        add_base_to_position(position, order_is_ask, base_asset_delta, quote_asset_delta);
    let _ = add_to_collateral_usd(position, ifixed::sub(pnl, fees), collateral_price);
    let unrealized = unrealized_pnl(position, mark_price);
    let margin = ifixed::add(
        effective_collateral_usd_value(position, collateral_price, collateral_haircut),
        unrealized,
    );
    // The fill is kept only if the margin stays non-negative and covers the liquidation fee on the
    // whole position, and the fill does not grow the position beyond `max_maker_abs_base`.
    // Otherwise the position is restored.
    let base_abs = ifixed::abs(base_now);
    let liquidation_fee_usd = ifixed::mul(ifixed::mul(base_abs, mark_price), liquidation_fee);
    let grows_past_max = max_maker_abs_base.is_some()
        && ifixed::greater_than(base_abs, ifixed::abs(base_before))
        && ifixed::greater_than(base_abs, *max_maker_abs_base.borrow());
    let keep = !ifixed::is_neg(margin)
        && !ifixed::greater_than(liquidation_fee_usd, margin)
        && !grows_past_max;
    if (keep) {
        return (true, pnl, base_now)
    };
    position.collateral = collateral_before;
    position.base_asset_amount = base_before;
    position.quote_asset_notional_amount = quote_before;
    (false, 0, base_before)
}

fun effective_collateral_usd_value(
    position: &Position,
    collateral_price: u256,
    collateral_haircut: u256
): u256 {
    let collateral_value = ifixed::mul(position.collateral, collateral_price);
    // The haircut only applies to positive collateral.
    if (collateral_haircut != 0 && !ifixed::is_neg(position.collateral)) {
        ifixed::mul(collateral_value, ifixed::sub(1_000_000_000_000_000_000, collateral_haircut))
    } else {
        collateral_value
    }
}

fun effective_collateral_usd_value_with_funding(
    position: &Position,
    collateral_price: u256,
    collateral_haircut: u256,
    funding: u256
): u256 {
    let collateral_value = ifixed::add(ifixed::mul(position.collateral, collateral_price), funding);
    if (collateral_haircut != 0 && !ifixed::is_neg(collateral_value)) {
        ifixed::mul(collateral_value, ifixed::sub(1_000_000_000_000_000_000, collateral_haircut))
    } else {
        collateral_value
    }
}

public fun ensure_margin_requirements(
    margin_before: u256,
    min_margin_before: u256,
    margin_now: u256,
    min_margin_now: u256,
    base_before: u256,
    base_now: u256,
) {
    if (ifixed::greater_than_eq(margin_now, min_margin_now)) {
        return
    };
    // Below the requirement, the action must reduce risk: the position had a requirement before,
    // stays solvent, neither raises the requirement nor flips sides, and does not worsen its
    // margin ratio.
    assert!(min_margin_before != 0, initial_margin_requirement_violated!());
    assert!(
        !ifixed::is_neg(margin_now) && !ifixed::is_neg(margin_before),
        position_bad_debt!(),
    );
    let requirement_not_increased = ifixed::less_than_eq(min_margin_now, min_margin_before);
    let same_side = base_before == 0
        || (base_now == 0 || ifixed::is_neg(base_before) == ifixed::is_neg(base_now));
    assert!(requirement_not_increased && same_side, initial_margin_requirement_violated!());
    if (ifixed::greater_than_eq(margin_now, margin_before)) {
        return
    };
    assert!(min_margin_now != min_margin_before, initial_margin_requirement_violated!());
    // margin_now / min_margin_now >= margin_before / min_margin_before, cross-multiplied.
    assert!(
        ifixed::greater_than_eq(
            ifixed::mul(margin_now, min_margin_before),
            ifixed::mul(margin_before, min_margin_now),
        ),
        initial_margin_requirement_violated!(),
    )
}

public fun unrealized_pnl(position: &Position, mark_price: u256): u256 {
    ifixed::sub(
        ifixed::mul(position.base_asset_amount, mark_price),
        position.quote_asset_notional_amount,
    )
}

public fun margin_requirement(
    position: &Position,
    mark_price: u256,
    margin_ratio: u256,
): u256 {
    ifixed::mul(ifixed::mul(position.abs_net_base(), mark_price), margin_ratio)
}

public fun abs_net_base(position: &Position): u256 {
    // The larger absolute base amount after filling either all pending bids or all pending asks.
    let base = position.base_asset_amount;
    let abs_base_after_bids = ifixed::abs(ifixed::add(base, position.bids_quantity));
    let abs_base_after_asks = ifixed::abs(ifixed::sub(base, position.asks_quantity));
    ifixed::max(abs_base_after_bids, abs_base_after_asks)
}

/// Settles the funding accrued since the position's funding rate snapshots into its collateral.
/// Returns whether anything changed, the funding in USD (negative when paid) and the new
/// collateral.
public fun settle_position_funding(
    position: &mut Position,
    collateral_price: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
): (bool, u256, u256) {
    let base = position.base_asset_amount;
    let is_short = ifixed::is_neg(base);
    let (rate_now, rate_before) = if (is_short) {
        (mkt_funding_rate_short, position.cum_funding_rate_short)
    } else {
        (mkt_funding_rate_long, position.cum_funding_rate_long)
    };
    let funding = if (rate_now != rate_before && base != 0) {
        // Longs pay when the cumulative rate rises, shorts when it falls. Both the collateral
        // change and the USD amount are rounded against the position, in a single step from the
        // exact product.
        let rate_delta = ifixed::sub(rate_now, rate_before);
        let rate_delta_abs = ifixed::abs(rate_delta);
        let base_abs = ifixed::abs(base);
        let receives = is_short != ifixed::is_neg(rate_delta);
        if (receives) {
            let collateral_delta = mul_div(rate_delta_abs, base_abs, collateral_price);
            position.collateral = ifixed::add(position.collateral, collateral_delta);
            mul_div(rate_delta_abs, base_abs, 1_000_000_000_000_000_000)
        } else {
            let collateral_delta = mul_div_up(rate_delta_abs, base_abs, collateral_price);
            position.collateral = ifixed::sub(position.collateral, collateral_delta);
            ifixed::neg(mul_div_up(rate_delta_abs, base_abs, 1_000_000_000_000_000_000))
        }
    } else {
        0
    };
    let changed = funding != 0
        || position.cum_funding_rate_long != mkt_funding_rate_long
        || position.cum_funding_rate_short != mkt_funding_rate_short;
    position.cum_funding_rate_long = mkt_funding_rate_long;
    position.cum_funding_rate_short = mkt_funding_rate_short;
    (changed, funding, position.collateral)
}

public fun calculate_position_funding_internal(
    position: &Position,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
): u256 {
    if (ifixed::is_neg(position.base_asset_amount)) {
        unrealized_funding(
            mkt_funding_rate_short,
            position.cum_funding_rate_short,
            position.base_asset_amount,
        )
    } else {
        unrealized_funding(
            mkt_funding_rate_long,
            position.cum_funding_rate_long,
            position.base_asset_amount,
        )
    }
}

public fun unrealized_funding(
    cum_funding_rate_now: u256,
    cum_funding_rate_before: u256,
    base_asset_amount: u256,
): u256 {
    if (cum_funding_rate_now == cum_funding_rate_before) {
        return 0
    };
    // A rising cumulative rate is a cost for longs and income for shorts.
    ifixed::mul(
        ifixed::sub(cum_funding_rate_now, cum_funding_rate_before),
        ifixed::neg(base_asset_amount),
    )
}

public fun calculate_bankruptcy_price(
    position: &Position,
    collateral_price: u256,
    tick_size: u64,
): u64 {
    let base = position.base_asset_amount;
    if (base == 0) {
        return 0
    };
    // The mark price at which `collateral value + base * price - quote notional` reaches zero,
    // rounded conservatively (up for longs, down for shorts) to 9 decimals and then to a tick.
    let is_long = !ifixed::is_neg(base);
    let quote_minus_collateral = ifixed::sub(
        position.quote_asset_notional_amount,
        ifixed::mul(collateral_price, position.collateral),
    );
    let mut price = ifixed::div(quote_minus_collateral, base);
    if (is_long && quote_minus_collateral != ifixed::mul(price, base)) {
        price = ifixed::add(price, 1);
    };
    price = ifixed::max(price, 0);
    let mut price_balance = ifixed::to_balance(price, 1_000_000_000);
    if (is_long && ifixed::from_balance(price_balance, 1_000_000_000) != price) {
        price_balance = price_balance + 1;
    };
    let remainder = price_balance % tick_size;
    if (remainder != 0) {
        if (is_long) {
            price_balance = price_balance + tick_size - remainder;
        } else {
            price_balance = price_balance - remainder;
        }
    };
    price_balance
}
