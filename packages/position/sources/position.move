// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module position::position;

use ifixed::ifixed;
use std::u256;

// === Errors and constants (original names from the published interface) ===

macro fun ifixed_overflow(): u64 { 2000 }
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

// All amounts are ifixed values: signed 18-decimal fixed point in two's complement. Several
// functions below carry ifixed arithmetic inlined, spelled with literals:
// - `x >= (1 << 255)` tests whether `x` is negative;
// - `(x ^ u256::max_value!()) + 1` and `((x ^ ((1 << 255) - 1)) + 1) ^ (1 << 255)` both compute
//   `-x` (the second one aborts only for the minimum value);
// - `1_000_000_000_000_000_000` is 1.0.

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

public fun add_to_collateral_usd(
    position: &mut Position,
    fixed_usd: u256,
    collateral_price: u256
): u256 {
    // Converts the USD amount into collateral units, rounding toward negative infinity, and adds
    // it to the collateral.
    let new_collateral;
    if (fixed_usd >= (1 << 255)) {
        let fixed_usd_abs = (fixed_usd ^ u256::max_value!()) + 1;
        let collateral_abs_delta =
            (fixed_usd_abs * 1_000_000_000_000_000_000 - 1) / collateral_price + 1;
        if (position.collateral >= (1 << 255)) {
            new_collateral = position.collateral - collateral_abs_delta;
            if (new_collateral < (1 << 255)) {
                abort ifixed_overflow!()
            }
        } else {
            if (position.collateral >= collateral_abs_delta) {
                new_collateral = position.collateral - collateral_abs_delta;
            } else {
                new_collateral =
                    ((collateral_abs_delta - position.collateral) ^ u256::max_value!()) + 1;
            }
        }
    } else {
        let collateral_delta = fixed_usd * 1_000_000_000_000_000_000 / collateral_price;
        if (position.collateral >= (1 << 255)) {
            let collateral_abs = (position.collateral ^ u256::max_value!()) + 1;
            if (collateral_delta >= collateral_abs) {
                new_collateral = collateral_delta - collateral_abs;
            } else {
                new_collateral = ((collateral_abs - collateral_delta) ^ u256::max_value!()) + 1;
            }
        } else {
            new_collateral = position.collateral + collateral_delta;
            if (new_collateral >= (1 << 255)) {
                abort ifixed_overflow!()
            }
        }
    };
    position.collateral = new_collateral;
    new_collateral
}

// Applies a fill of `base_asset_delta` for `quote_asset_delta` (both positive) on side `side`
// (true for asks). Reducing a position realizes the pnl of the closed part, whose entry notional is
// taken pro rata from the position's notional; the rest of a fill that flips the position opens it
// on the other side. Returns the realized pnl and the new base amount.
#[allow(dead_code)]
public fun add_base_to_position(
    position: &mut Position,
    side: bool,
    base_asset_delta: u256,
    quote_asset_delta: u256,
): (u256, u256) {
    let base = position.base_asset_amount;
    let pnl;
    if (side) {
        if (base < (1 << 255)) {
            // Selling from a long (or flat) position.
            let quote = position.quote_asset_notional_amount;
            if (base_asset_delta <= base) {
                let closed_quote = (quote * base_asset_delta + base - 1) / base;
                position.base_asset_amount = base - base_asset_delta;
                position.quote_asset_notional_amount = quote - closed_quote;
                if (quote_asset_delta >= closed_quote) {
                    return (quote_asset_delta - closed_quote, position.base_asset_amount)
                };
                return (
                    (((closed_quote - quote_asset_delta) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255),
                    position.base_asset_amount,
                )
            };
            // The long is closed and a short opened with the rest of the fill.
            let closing_quote = quote_asset_delta * base / base_asset_delta;
            if (closing_quote >= quote) {
                pnl = closing_quote - quote;
            } else {
                pnl = (((quote - closing_quote) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
            };
            position.base_asset_amount = ((base_asset_delta - base) ^ u256::max_value!()) + 1;
            position.quote_asset_notional_amount =
                (((quote_asset_delta - closing_quote) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
            return (pnl, position.base_asset_amount)
        };
        // Selling into a short position.
        let new_base_abs = (base ^ u256::max_value!()) + 1 + base_asset_delta;
        assert!(new_base_abs < (1 << 255), ifixed_overflow!());
        position.base_asset_amount = (new_base_abs ^ u256::max_value!()) + 1;
        let quote = position.quote_asset_notional_amount;
        let new_quote_abs = (((quote ^ ((1 << 255) - 1)) + 1) ^ (1 << 255)) + quote_asset_delta;
        assert!(new_quote_abs < (1 << 255), ifixed_overflow!());
        position.quote_asset_notional_amount =
            ((new_quote_abs ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
        return (0, position.base_asset_amount)
    };
    if (base < (1 << 255)) {
        // Buying into a long (or flat) position.
        let new_base = base + base_asset_delta;
        assert!(new_base < (1 << 255), ifixed_overflow!());
        let new_quote = position.quote_asset_notional_amount + quote_asset_delta;
        assert!(new_quote < (1 << 255), ifixed_overflow!());
        position.base_asset_amount = new_base;
        position.quote_asset_notional_amount = new_quote;
        return (0, position.base_asset_amount)
    };
    // Buying from a short position.
    let base_abs = (base ^ u256::max_value!()) + 1;
    let quote_abs = ((position.quote_asset_notional_amount ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
    if (base_asset_delta <= base_abs) {
        let closed_quote = quote_abs * base_asset_delta / base_abs;
        position.base_asset_amount =
            (((base_abs - base_asset_delta) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
        position.quote_asset_notional_amount =
            (((quote_abs - closed_quote) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
        if (closed_quote >= quote_asset_delta) {
            return (closed_quote - quote_asset_delta, position.base_asset_amount)
        };
        return (
            (((quote_asset_delta - closed_quote) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255),
            position.base_asset_amount,
        )
    };
    // The short is closed and a long opened with the rest of the fill.
    position.base_asset_amount = base_asset_delta - base_abs;
    let closing_quote = (quote_asset_delta * base_abs - 1) / base_asset_delta + 1;
    if (quote_abs >= closing_quote) {
        pnl = quote_abs - closing_quote;
    } else {
        pnl = (((closing_quote - quote_abs) ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
    };
    position.quote_asset_notional_amount = quote_asset_delta - closing_quote;
    (pnl, position.base_asset_amount)
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
    // Change of the long open interest: max(base_now, 0) - max(base_before, 0).
    let open_interest_delta;
    if (base_now < (1 << 255)) {
        if (base_before < (1 << 255)) {
            if (base_now >= base_before) {
                open_interest_delta = base_now - base_before;
            } else {
                open_interest_delta = ((base_before - base_now) ^ u256::max_value!()) + 1;
            }
        } else {
            open_interest_delta = base_now;
        }
    } else {
        if (base_before < (1 << 255)) {
            open_interest_delta = ((base_before ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
        } else {
            open_interest_delta = 0;
        }
    };
    let pnl = ifixed::add(ask_pnl, bid_pnl);
    let quote_filled = quote_filled_ask + quote_filled_bid;
    // A negative taker fee is a rebate; the fee amount is rounded toward zero either way.
    let is_rebate = taker_fee >= (1 << 255);
    let taker_fee_abs_amount = (if (is_rebate) (taker_fee ^ u256::max_value!()) + 1 else taker_fee)
        * quote_filled
        / 1_000_000_000_000_000_000;
    let taker_fee_amount;
    if (is_rebate) {
        taker_fee_amount = ((taker_fee_abs_amount ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
    } else {
        taker_fee_amount = taker_fee_abs_amount;
    };
    let integrator_fee_amount = integrator_fee * quote_filled / 1_000_000_000_000_000_000;
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
    // Otherwise the position is restored. The `loop` only serves as a block to break out of.
    loop {
        if (margin >= (1 << 255)) break;
        let base = position.base_asset_amount;
        let base_abs;
        if (base >= (1 << 255)) {
            base_abs = (base ^ u256::max_value!()) + 1;
        } else {
            base_abs = base;
        };
        let liquidation_fee_usd = base_abs * mark_price / 1_000_000_000_000_000_000
            * liquidation_fee
            / 1_000_000_000_000_000_000;
        if (liquidation_fee_usd > margin) break;
        let exceeds_max_base = max_maker_abs_base.is_some()
            && (ifixed::greater_than(ifixed::abs(base_now), ifixed::abs(base_before))
                && ifixed::greater_than(base_abs, *max_maker_abs_base.borrow()));
        if (exceeds_max_base) break;
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

// Settles the funding accrued since the position's funding rate snapshots into its collateral.
// Returns whether anything changed, the funding in USD (negative when paid) and the new collateral.
#[allow(dead_code)]
public fun settle_position_funding(
    position: &mut Position,
    collateral_price: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
): (bool, u256, u256) {
    let is_short = position.base_asset_amount >= (1 << 255);
    let (rate_now, rate_before, base_abs);
    if (is_short) {
        rate_now = mkt_funding_rate_short;
        rate_before = position.cum_funding_rate_short;
        base_abs = (position.base_asset_amount ^ u256::max_value!()) + 1;
    } else {
        rate_now = mkt_funding_rate_long;
        rate_before = position.cum_funding_rate_long;
        base_abs = position.base_asset_amount;
    };
    let new_collateral;
    let funding;
    'settle: {
        if (rate_now != rate_before) {
            if (base_abs != 0) {
                // |rate_now - rate_before| and the direction of the change.
                let rate_now_is_neg = rate_now >= (1 << 255);
                let (rate_decreased, rate_delta);
                if ((rate_before >= (1 << 255)) == rate_now_is_neg) {
                    if (rate_now >= rate_before) {
                        rate_delta = rate_now - rate_before;
                        rate_decreased = false;
                    } else {
                        rate_delta = rate_before - rate_now;
                        rate_decreased = true;
                    }
                } else {
                    rate_decreased = rate_now_is_neg;
                    if (rate_now_is_neg) {
                        rate_delta = (rate_now ^ u256::max_value!()) + 1 + rate_before;
                    } else {
                        rate_delta = (rate_before ^ u256::max_value!()) + 1 + rate_now;
                    }
                };
                // Scaled by 10^36: dividing by the price gives collateral, by 10^18 gives USD.
                let funding_scaled = rate_delta * base_abs;
                // Longs pay when the cumulative rate goes up, shorts when it goes down.
                if (is_short != rate_decreased) {
                    // Funding received, rounded down.
                    let collateral_delta = funding_scaled / collateral_price;
                    funding = funding_scaled / 1_000_000_000_000_000_000;
                    if (collateral_delta != 0) {
                        if (position.collateral >= (1 << 255)) {
                            let collateral_abs = (position.collateral ^ u256::max_value!()) + 1;
                            if (collateral_delta >= collateral_abs) {
                                new_collateral = collateral_delta - collateral_abs;
                            } else {
                                new_collateral = position.collateral + collateral_delta;
                            }
                        } else {
                            new_collateral = position.collateral + collateral_delta;
                            assert!(!(new_collateral >= (1 << 255)), ifixed_overflow!())
                        };
                        position.collateral = new_collateral
                    } else {
                        new_collateral = position.collateral;
                    }
                } else {
                    // Funding paid, rounded up.
                    let collateral_delta =
                        (funding_scaled + collateral_price - 1) / collateral_price;
                    if (position.collateral >= (1 << 255)) {
                        new_collateral = position.collateral - collateral_delta;
                        assert!(new_collateral >= (1 << 255), ifixed_overflow!())
                    } else {
                        if (position.collateral >= collateral_delta) {
                            new_collateral = position.collateral - collateral_delta;
                        } else {
                            new_collateral =
                                ((collateral_delta - position.collateral) ^ u256::max_value!()) + 1;
                        }
                    };
                    let funding_abs =
                        (funding_scaled + 999_999_999_999_999_999) / 1_000_000_000_000_000_000;
                    funding = ((funding_abs ^ ((1 << 255) - 1)) + 1) ^ (1 << 255);
                    position.collateral = new_collateral
                };
                return 'settle
            }
        };
        new_collateral = position.collateral;
        funding = 0;
    };
    let changed = funding != 0
        || position.cum_funding_rate_long != mkt_funding_rate_long
        || position.cum_funding_rate_short != mkt_funding_rate_short;
    position.cum_funding_rate_long = mkt_funding_rate_long;
    position.cum_funding_rate_short = mkt_funding_rate_short;
    (changed, funding, new_collateral)
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
