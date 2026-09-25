// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::adl;

use authority_cap::authority::AuthorityCap;
use haneul::clock::Clock;
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::authority::{ADL, PACKAGE};
use perpetuals::clearing_house::{Self, ClearingHouse};
use perpetuals::events;
use perpetuals::market;
use perpetuals::registry::Registry;

// === Errors and constants (original names from the published interface) ===

macro fun size_not_multiple_of_lot_size(): u64 { 6000 }
macro fun adl_counterparties_mismatch(): u64 { 6001 }
macro fun adl_counterparty_insufficient(): u64 { 6002 }
macro fun adl_bad_debt_position_not_closed(): u64 { 6003 }
macro fun adl_weights_do_not_sum_to_one(): u64 { 6004 }

// === Functions ===

public fun execute_adl<T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<PACKAGE, ADL>,
    registry: &Registry,
    bad_debt_account_id: u64,
    bad_debt_open_orders: vector<u128>,
    counterparty_account_ids: vector<u64>,
    sizes_reduced: vector<u64>,
    collateral_distribution: vector<u64>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    clearing_house.assert_package_version();
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    clearing_house.assert_market_is_not_closed();

    let now = clock.timestamp_ms();
    let ch_id = object::id(clearing_house);
    let book_price = clearing_house.book_price();
    let (market_params, market_state) = clearing_house.borrow_mut_market_objects();
    market::try_update_funding(market_params, market_state, base_oracle, clock, &ch_id, book_price);
    let collateral_price = market::collateral_oracle_price(market_params, collateral_oracle, clock);
    let (index_price, index_twap_price) = market::base_oracle_price_and_twap_price(
        market_params,
        base_oracle,
        clock,
    );
    market::assert_index_twap_divergence_within_limit(market_params, index_price, index_twap_price);
    let book_or_index_price;
    if (book_price.is_none()) {
        book_or_index_price = index_price;
    } else {
        book_or_index_price = *book_price.borrow();
    };
    let mark_price = market::calculate_mark_price(
        market_state,
        market_params,
        index_twap_price,
        book_or_index_price,
        now,
    );
    execute_adl_(
        clearing_house,
        bad_debt_account_id,
        bad_debt_open_orders,
        counterparty_account_ids,
        sizes_reduced,
        collateral_distribution,
        mark_price,
        collateral_price,
    )
}

public fun execute_closed_market_adl<T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<PACKAGE, ADL>,
    registry: &Registry,
    bad_debt_account_id: u64,
    bad_debt_open_orders: vector<u128>,
    counterparty_account_ids: vector<u64>,
    sizes_reduced: vector<u64>,
    collateral_distribution: vector<u64>,
) {
    clearing_house.assert_package_version();
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    let (mark_price, collateral_price) = clearing_house.closed_market_adl_prices();
    execute_adl_(
        clearing_house,
        bad_debt_account_id,
        bad_debt_open_orders,
        counterparty_account_ids,
        sizes_reduced,
        collateral_distribution,
        mark_price,
        collateral_price,
    )
}

/// Auto-deleverages a position with negative equity: its orders are canceled, its position is
/// closed at the mark price and taken over by the counterparties (`sizes_reduced[i]` each, on the
/// opposite side), and its negative collateral is split among them by `collateral_distribution`
/// (IFixed weights summing to 1).
fun execute_adl_<T>(
    clearing_house: &mut ClearingHouse<T>,
    bad_debt_account_id: u64,
    bad_debt_open_orders: vector<u128>,
    counterparty_account_ids: vector<u64>,
    sizes_reduced: vector<u64>,
    collateral_distribution: vector<u64>,
    mark_price: u256,
    collateral_price: u256,
) {
    let num_counterparties = counterparty_account_ids.length();
    assert!(num_counterparties == sizes_reduced.length(), adl_counterparties_mismatch!());
    assert!(num_counterparties == collateral_distribution.length(), adl_counterparties_mismatch!());

    let ch_id = object::id(clearing_house);
    let (market_params, market_state) = clearing_house.market_objects();
    let lot_size = market_params.lot_size();
    let (cum_funding_rate_long, cum_funding_rate_short) = market_state.cum_funding_rates();
    let mark_price_b9 = ifixed::to_balance(mark_price, 1_000_000_000);

    let bad_debt_position = clearing_house.borrow_mut_position(bad_debt_account_id);
    clearing_house::settle_position_funding_and_emit(
        bad_debt_position,
        collateral_price,
        cum_funding_rate_long,
        cum_funding_rate_short,
        &ch_id,
        bad_debt_account_id,
    );
    let is_long = bad_debt_position.is_long_or_flat();
    let equity = ifixed::add(
        ifixed::mul(bad_debt_position.collateral(), collateral_price),
        bad_debt_position.unrealized_pnl(mark_price),
    );
    if (ifixed::greater_than(equity, 0)) {
        return
    };
    assert!(num_counterparties > 0, adl_counterparties_mismatch!());

    // Cancel the account's resting orders so that its position can be closed completely.
    let orderbook = clearing_house.borrow_mut_orderbook();
    let (canceled_ask_size, canceled_bid_size, canceled_orders) = if (
        bad_debt_open_orders.length() != 0
    ) {
        let orderbook = orderbook;
        let account_id = bad_debt_account_id;
        let order_ids = &bad_debt_open_orders;
        let ch_id = ch_id;
        clearing_house::force_cancel_orders(orderbook, account_id, order_ids, ch_id, 2)
    } else {
        (0, 0, 0)
    };
    let bad_debt_position = clearing_house.borrow_mut_position(bad_debt_account_id);
    // The named blocks stand in for the original macro calls; they keep the compiled control flow
    // identical to the published bytecode.
    'asks: {
        let position = bad_debt_position;
        let size = canceled_ask_size;
        position.sub_from_pending_amount(true, ifixed::from_u128balance(size, 1_000_000_000));
    };
    'bids: {
        let position = bad_debt_position;
        let size = canceled_bid_size;
        position.sub_from_pending_amount(false, ifixed::from_u128balance(size, 1_000_000_000));
    };
    bad_debt_position.update_pending_orders(false, canceled_orders);
    let (pending_ask_size, pending_bid_size) = bad_debt_position.pending_base_amounts_by_side();
    assert!(
        pending_ask_size == 0
            && pending_bid_size == 0
            && bad_debt_position.pending_order_count() == 0,
        adl_bad_debt_position_not_closed!(),
    );

    // Close the bad-debt position at the mark price.
    let (mut base, _) = bad_debt_position.base_and_quote_amounts();
    let was_flat = base == 0;
    let size_b9 = ifixed::to_u128balance(ifixed::abs(base), 1_000_000_000);
    let mut base_delta = ifixed::from_u128balance(size_b9, 1_000_000_000);
    let mut quote_delta = (size_b9 as u256) * (mark_price_b9 as u256);
    let mut pnl;
    if (size_b9 != 0) {
        (pnl, _) = bad_debt_position.add_base_to_position(is_long, base_delta, quote_delta);
    } else {
        pnl = 0;
    };
    let quote;
    (base, quote) = bad_debt_position.base_and_quote_amounts();
    let _ = bad_debt_position.add_to_collateral_usd(pnl, collateral_price);
    assert!(base == 0 && quote == 0, adl_bad_debt_position_not_closed!());
    let bad_debt_collateral = bad_debt_position.collateral();
    let mut remaining_collateral = bad_debt_collateral;
    let _ = bad_debt_position.reset_collateral();

    // Hand the closed size and the (negative) collateral over to the counterparties, from the
    // last one to the first; the first one also absorbs the rounding remainder of the collateral.
    let mut i = num_counterparties - 1;
    let mut total_size_reduced = 0u128;
    let mut total_weight = 0u256;
    loop {
        let weight = (collateral_distribution[i] as u256);
        total_weight = total_weight + weight;
        let counterparty_account_id = counterparty_account_ids[i];
        let position = clearing_house.borrow_mut_position(counterparty_account_id);
        clearing_house::settle_position_funding_and_emit(
            position,
            collateral_price,
            cum_funding_rate_long,
            cum_funding_rate_short,
            &ch_id,
            counterparty_account_id,
        );
        (base, _) = position.base_and_quote_amounts();
        let size_reduced = sizes_reduced[i];
        assert!(size_reduced % lot_size == 0, size_not_multiple_of_lot_size!());
        // The counterparty must hold at least `size_reduced` on the opposite side.
        assert!(
            (was_flat || position.is_long_or_flat() != is_long)
                && ifixed::less_than_eq(
                    ifixed::from_balance(size_reduced, 1_000_000_000),
                    ifixed::abs(base),
                ),
            adl_counterparty_insufficient!(),
        );
        total_size_reduced = total_size_reduced + (size_reduced as u128);

        (base_delta, quote_delta) = clearing_house::fill_base_and_quote_deltas(
            mark_price_b9,
            size_reduced,
        );
        (pnl, _) = position.add_base_to_position(!is_long, base_delta, quote_delta);
        let _ = position.add_to_collateral_usd(pnl, collateral_price);
        let collateral_share = if (i == 0) {
            remaining_collateral
        } else {
            ifixed::mul(bad_debt_collateral, weight)
        };
        position.add_to_collateral(collateral_share);
        remaining_collateral = ifixed::sub(remaining_collateral, collateral_share);
        events::e25(
            ch_id,
            bad_debt_account_id,
            size_reduced,
            ifixed::add(ifixed::div(pnl, collateral_price), collateral_share),
            mark_price_b9,
            counterparty_account_id,
            is_long,
        );
        if (i == 0) {
            break
        };
        i = i - 1;
    };
    assert!(total_size_reduced == size_b9, adl_bad_debt_position_not_closed!());
    assert!(total_weight == 1_000_000_000_000_000_000, adl_weights_do_not_sum_to_one!());

    // The closed size leaves the market on both sides.
    if (total_size_reduced != 0) {
        let market_state = clearing_house.borrow_mut_market_state();
        let size = total_size_reduced;
        market::add_to_open_interest(
            market_state,
            ifixed::neg(ifixed::from_u128balance(size, 1_000_000_000)),
        )
    }
}
