// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::market;

use haneul::clock::Clock;
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::events;
use perpetuals::registry::Config;

// === Errors and constants (original names from the published interface) ===

macro fun bad_index_price(): u64 { 1000 }
macro fun invalid_base_price_feed_storage(): u64 { 1001 }
macro fun invalid_collateral_price_feed_storage(): u64 { 1002 }
macro fun index_twap_divergence(): u64 { 1003 }
macro fun priority_gas_price_not_allowed(): u64 { 1004 }
macro fun invalid_lot_and_tick_size_update(): u64 { 1007 }
macro fun invalid_min_order_usd_value(): u64 { 1008 }
macro fun invalid_max_pending_orders(): u64 { 1009 }
macro fun invalid_max_open_interest(): u64 { 1010 }
macro fun invalid_max_open_interest_position_percent(): u64 { 1011 }
macro fun invalid_max_open_interest_position_threshold(): u64 { 1012 }
macro fun invalid_max_bad_debt(): u64 { 1013 }
macro fun invalid_max_socialize_losses_mr_decrease(): u64 { 1014 }
macro fun invalid_collateral_haircut(): u64 { 1015 }
macro fun invalid_margin_ratios(): u64 { 1016 }
macro fun invalid_funding_parameters(): u64 { 1017 }
macro fun invalid_priority_taker_fee(): u64 { 1018 }
macro fun invalid_twap_parameters(): u64 { 1019 }
macro fun invalid_market_fees(): u64 { 1020 }
macro fun negative_maker_fee_not_covered(): u64 { 1021 }
macro fun negative_taker_fee_not_covered(): u64 { 1022 }
macro fun invalid_liquidation_fees(): u64 { 1023 }
macro fun liquidation_fees_exceed_maintenance_margin_ratio(): u64 { 1024 }
macro fun invalid_oracle_tolerance(): u64 { 1025 }
macro fun invalid_lot_and_tick_sizes(): u64 { 1026 }
macro fun invalid_max_book_index_spread(): u64 { 1027 }
macro fun invalid_max_index_twap_divergence(): u64 { 1028 }

// === Types ===

public struct MarketParams has copy, drop, store {
    core_params: CoreParams,
    fees_params: FeesParams,
    twap_params: TwapParams,
    limits_params: LimitsParams,
}

public struct CoreParams has copy, drop, store {
    base_storage_id: u32,
    collateral_storage_id: u32,
    base_source_id: u16,
    collateral_source_id: u16,
    base_pfs_tolerance: u64,
    collateral_pfs_tolerance: u64,
    lot_size: u64,
    tick_size: u64,
    scaling_factor: u256,
    collateral_haircut: u256,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
}

public struct FeesParams has copy, drop, store {
    maker_fee: u256,
    taker_fee: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    priority_taker_fee: Option<u256>,
}

public struct TwapParams has copy, drop, store {
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
}

public struct LimitsParams has copy, drop, store {
    min_order_usd_value: u256,
    max_pending_orders: u64,
    max_open_interest: u256,
    max_open_interest_threshold: u256,
    max_open_interest_position_percent: u256,
    max_book_index_spread: u256,
    max_index_twap_divergence: u256,
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
}

public struct MarketState has store {
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
    funding_last_upd_ms: u64,
    premium_twap: u256,
    premium_twap_last_upd_ms: u64,
    spread_twap: u256,
    spread_twap_last_upd_ms: u64,
    open_interest: u256,
    fees_accrued: u256,
}

// === Functions ===

fun option_u64_or(value: &Option<u64>, fallback: u64): u64 {
    if (value.is_some()) *value.borrow() else fallback
}

fun option_u256_or(value: &Option<u256>, fallback: u256): u256 {
    if (value.is_some()) *value.borrow() else fallback
}

fun option_u16_or(value: &Option<u16>, fallback: u16): u16 {
    if (value.is_some()) *value.borrow() else fallback
}

public(package) fun create_market_objects(
    registry_config: &Config,
    clock: &Clock,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
    base_storage_id: u32,
    collateral_storage_id: u32,
    base_source_id: u16,
    collateral_source_id: u16,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
    maker_fee: u256,
    taker_fee: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    lot_size: u64,
    tick_size: u64,
    scaling_factor: u256,
): (MarketParams, MarketState) {
    assert_margin_ratios(margin_ratio_initial, margin_ratio_maintenance);
    assert_funding_parameters(
        registry_config,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
    );
    assert_spread_twap_parameters(registry_config, spread_twap_frequency_ms, spread_twap_period_ms);
    assert_market_fees(registry_config, maker_fee, taker_fee);
    // Default priority taker fee: 0.1%.
    assert_priority_taker_fee(registry_config, option::some(1_000_000_000_000_000));
    assert_liquidation_fees(registry_config, liquidation_fee, insurance_fund_fee);
    assert_liquidation_fees_against_mmr(
        margin_ratio_maintenance,
        liquidation_fee,
        insurance_fund_fee,
    );
    assert_lot_and_tick_sizes(lot_size, tick_size);

    let params = create_market_params(
        registry_config,
        margin_ratio_initial,
        margin_ratio_maintenance,
        base_storage_id,
        collateral_storage_id,
        base_source_id,
        collateral_source_id,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
        spread_twap_frequency_ms,
        spread_twap_period_ms,
        maker_fee,
        taker_fee,
        liquidation_fee,
        insurance_fund_fee,
        lot_size,
        tick_size,
        scaling_factor,
    );
    let state = create_market_state(clock.timestamp_ms());
    (params, state)
}

public(package) fun try_update_funding(
    params: &MarketParams,
    state: &mut MarketState,
    oracle: &PriceFeedStorage,
    clock: &Clock,
    ch_id: &ID,
    book_price_opt: Option<u256>
) {
    let (index_price, index_twap_price) = base_oracle_price_and_twap_price(params, oracle, clock);
    assert_index_twap_divergence_within_limit(params, index_price, index_twap_price);
    // Without a book price (empty side), the index price stands in for it.
    let (actual_book_price, clipped_book_price) = if (book_price_opt.is_none()) {
        (index_price, index_price)
    } else {
        let book_price = *book_price_opt.borrow();
        (book_price, clip_max_book_index_spread(params, book_price, index_price))
    };

    let now = clock.timestamp_ms();
    if (now >= state.premium_twap_last_upd_ms + params.twap_params.premium_twap_frequency_ms) {
        state.update_premium_twap(
            params,
            index_price,
            actual_book_price,
            clipped_book_price,
            now,
            ch_id,
        )
    };
    if (now >= state.spread_twap_last_upd_ms + params.twap_params.spread_twap_frequency_ms) {
        state.update_spread_twap(
            params,
            index_price,
            actual_book_price,
            clipped_book_price,
            now,
            ch_id,
        )
    };
    try_update_fundings(params, state, now, ch_id)
}

public(package) fun try_update_twaps(
    params: &MarketParams,
    state: &mut MarketState,
    oracle: &PriceFeedStorage,
    clock: &Clock,
    ch_id: &ID,
    book_price_opt: Option<u256>
) {
    let (index_price, index_twap_price) = base_oracle_price_and_twap_price(params, oracle, clock);
    assert_index_twap_divergence_within_limit(params, index_price, index_twap_price);
    let (actual_book_price, clipped_book_price) = if (book_price_opt.is_none()) {
        (index_price, index_price)
    } else {
        let book_price = *book_price_opt.borrow();
        (book_price, clip_max_book_index_spread(params, book_price, index_price))
    };

    let now = clock.timestamp_ms();
    if (now >= state.premium_twap_last_upd_ms + params.twap_params.premium_twap_frequency_ms) {
        state.update_premium_twap(
            params,
            index_price,
            actual_book_price,
            clipped_book_price,
            now,
            ch_id,
        )
    };
    if (now >= state.spread_twap_last_upd_ms + params.twap_params.spread_twap_frequency_ms) {
        state.update_spread_twap(
            params,
            index_price,
            actual_book_price,
            clipped_book_price,
            now,
            ch_id,
        )
    }
}

public(package) fun set_core_params(
    params: &mut MarketParams,
    ch_id: &ID,
    lot_size: Option<u64>,
    tick_size: Option<u64>,
    collateral_haircut: Option<u256>,
) {
    let lot_size = option_u64_or(&lot_size, params.core_params.lot_size);
    let tick_size = option_u64_or(&tick_size, params.core_params.tick_size);
    let collateral_haircut = option_u256_or(
        &collateral_haircut,
        params.core_params.collateral_haircut,
    );
    assert_lot_and_tick_sizes(lot_size, tick_size);
    // New sizes must divide the current ones so that resting orders stay on the new grid.
    assert!(
        params.core_params.lot_size % lot_size == 0
            && params.core_params.tick_size % tick_size == 0,
        invalid_lot_and_tick_size_update!(),
    );
    assert!(
        ifixed::greater_than_eq(collateral_haircut, 0)
            && ifixed::less_than(collateral_haircut, 1_000_000_000_000_000_000),
        invalid_collateral_haircut!(),
    );

    params.core_params.lot_size = lot_size;
    params.core_params.tick_size = tick_size;
    params.core_params.collateral_haircut = collateral_haircut;
    events::e46(*ch_id, lot_size, tick_size, collateral_haircut)
}

public(package) fun update_margin_ratios(
    params: &mut MarketParams,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
) {
    assert_margin_ratios(margin_ratio_initial, margin_ratio_maintenance);
    assert_liquidation_fees_against_mmr(
        margin_ratio_maintenance,
        params.fees_params.liquidation_fee,
        params.fees_params.insurance_fund_fee,
    );
    params.core_params.margin_ratio_initial = margin_ratio_initial;
    params.core_params.margin_ratio_maintenance = margin_ratio_maintenance
}

public(package) fun set_fee_params(
    params: &mut MarketParams,
    registry_config: &Config,
    ch_id: &ID,
    maker_fee: Option<u256>,
    taker_fee: Option<u256>,
    liquidation_fee: Option<u256>,
    insurance_fund_fee: Option<u256>,
    priority_taker_fee: Option<Option<u256>>,
) {
    let maker_fee = option_u256_or(&maker_fee, params.fees_params.maker_fee);
    let taker_fee = option_u256_or(&taker_fee, params.fees_params.taker_fee);
    let liquidation_fee = option_u256_or(&liquidation_fee, params.fees_params.liquidation_fee);
    let insurance_fund_fee = option_u256_or(
        &insurance_fund_fee,
        params.fees_params.insurance_fund_fee,
    );
    // `some(none)` disables the priority taker fee; `none` keeps the current setting.
    let priority_taker_fee = if (priority_taker_fee.is_some()) {
        priority_taker_fee.destroy_some()
    } else {
        params.fees_params.priority_taker_fee
    };
    assert_market_fees(registry_config, maker_fee, taker_fee);
    assert_priority_taker_fee(registry_config, priority_taker_fee);
    assert_liquidation_fees(registry_config, liquidation_fee, insurance_fund_fee);
    assert_liquidation_fees_against_mmr(
        params.core_params.margin_ratio_maintenance,
        liquidation_fee,
        insurance_fund_fee,
    );

    params.fees_params.maker_fee = maker_fee;
    params.fees_params.taker_fee = taker_fee;
    params.fees_params.liquidation_fee = liquidation_fee;
    params.fees_params.insurance_fund_fee = insurance_fund_fee;
    params.fees_params.priority_taker_fee = priority_taker_fee;
    events::e44(
        *ch_id,
        maker_fee,
        taker_fee,
        liquidation_fee,
        insurance_fund_fee,
        priority_taker_fee,
    )
}

public(package) fun set_twap_params(
    params: &mut MarketParams,
    registry_config: &Config,
    ch_id: &ID,
    funding_frequency_ms: Option<u64>,
    funding_period_ms: Option<u64>,
    premium_twap_frequency_ms: Option<u64>,
    premium_twap_period_ms: Option<u64>,
    spread_twap_frequency_ms: Option<u64>,
    spread_twap_period_ms: Option<u64>,
) {
    let funding_frequency_ms = option_u64_or(
        &funding_frequency_ms,
        params.twap_params.funding_frequency_ms,
    );
    let funding_period_ms = option_u64_or(&funding_period_ms, params.twap_params.funding_period_ms);
    let premium_twap_frequency_ms = option_u64_or(
        &premium_twap_frequency_ms,
        params.twap_params.premium_twap_frequency_ms,
    );
    let premium_twap_period_ms = option_u64_or(
        &premium_twap_period_ms,
        params.twap_params.premium_twap_period_ms,
    );
    let spread_twap_frequency_ms = option_u64_or(
        &spread_twap_frequency_ms,
        params.twap_params.spread_twap_frequency_ms,
    );
    let spread_twap_period_ms = option_u64_or(
        &spread_twap_period_ms,
        params.twap_params.spread_twap_period_ms,
    );
    assert_funding_parameters(
        registry_config,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
    );
    assert_spread_twap_parameters(registry_config, spread_twap_frequency_ms, spread_twap_period_ms);

    params.twap_params.funding_frequency_ms = funding_frequency_ms;
    params.twap_params.funding_period_ms = funding_period_ms;
    params.twap_params.premium_twap_frequency_ms = premium_twap_frequency_ms;
    params.twap_params.premium_twap_period_ms = premium_twap_period_ms;
    params.twap_params.spread_twap_frequency_ms = spread_twap_frequency_ms;
    params.twap_params.spread_twap_period_ms = spread_twap_period_ms;
    events::e45(
        *ch_id,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
        spread_twap_frequency_ms,
        spread_twap_period_ms,
    )
}

public(package) fun set_risk_limit_params(
    params: &mut MarketParams,
    registry_config: &Config,
    ch_id: &ID,
    min_order_usd_value: Option<u256>,
    max_pending_orders: Option<u64>,
    max_open_interest: Option<u256>,
    max_open_interest_threshold: Option<u256>,
    max_open_interest_position_percent: Option<u256>,
    max_book_index_spread: Option<u256>,
    max_index_twap_divergence: Option<u256>,
    max_bad_debt: Option<u256>,
    max_socialize_losses_mr_decrease: Option<u256>,
) {
    let min_order_usd_value = option_u256_or(
        &min_order_usd_value,
        params.limits_params.min_order_usd_value,
    );
    let max_pending_orders = option_u64_or(
        &max_pending_orders,
        params.limits_params.max_pending_orders,
    );
    let max_open_interest = option_u256_or(
        &max_open_interest,
        params.limits_params.max_open_interest,
    );
    // While the threshold still equals the open interest cap, it keeps tracking the cap unless it
    // is set explicitly.
    let current_threshold = params.limits_params.max_open_interest_threshold;
    let max_open_interest_threshold = if (
        current_threshold == params.limits_params.max_open_interest
            && !max_open_interest_threshold.is_some()
    ) {
        max_open_interest
    } else {
        option_u256_or(&max_open_interest_threshold, current_threshold)
    };
    let max_open_interest_position_percent = option_u256_or(
        &max_open_interest_position_percent,
        params.limits_params.max_open_interest_position_percent,
    );
    let max_book_index_spread = option_u256_or(
        &max_book_index_spread,
        params.limits_params.max_book_index_spread,
    );
    let max_index_twap_divergence = option_u256_or(
        &max_index_twap_divergence,
        params.limits_params.max_index_twap_divergence,
    );
    let max_bad_debt = option_u256_or(&max_bad_debt, params.limits_params.max_bad_debt);
    let max_socialize_losses_mr_decrease = option_u256_or(
        &max_socialize_losses_mr_decrease,
        params.limits_params.max_socialize_losses_mr_decrease,
    );

    assert!(
        ifixed::less_than_eq(min_order_usd_value, registry_config.up_min_order_usd_value())
            && ifixed::greater_than_eq(
                min_order_usd_value,
                registry_config.low_min_order_usd_value(),
            ),
        invalid_min_order_usd_value!(),
    );
    assert!(
        max_pending_orders > 0 && max_pending_orders <= registry_config.up_max_pending_orders(),
        invalid_max_pending_orders!(),
    );
    assert!(
        ifixed::greater_than(max_open_interest, 0)
            && ifixed::less_than_eq(max_open_interest_threshold, max_open_interest),
        invalid_max_open_interest!(),
    );
    assert!(
        ifixed::greater_than_eq(max_book_index_spread, 0)
            && ifixed::less_than_eq(max_book_index_spread, registry_config.max_book_index_spread()),
        invalid_max_book_index_spread!(),
    );
    assert!(
        ifixed::greater_than_eq(max_index_twap_divergence, 0)
            && ifixed::less_than_eq(
                max_index_twap_divergence,
                registry_config.max_index_twap_divergence(),
            ),
        invalid_max_index_twap_divergence!(),
    );
    assert!(
        ifixed::greater_than(max_open_interest_position_percent, 0)
            && ifixed::less_than_eq(max_open_interest_position_percent, 1_000_000_000_000_000_000),
        invalid_max_open_interest_position_percent!(),
    );
    assert!(
        ifixed::greater_than(max_open_interest_threshold, 0),
        invalid_max_open_interest_position_threshold!(),
    );
    assert!(ifixed::greater_than_eq(max_bad_debt, 0), invalid_max_bad_debt!());
    assert!(
        ifixed::greater_than_eq(max_socialize_losses_mr_decrease, 0)
            && ifixed::less_than_eq(max_socialize_losses_mr_decrease, 1_000_000_000_000_000_000),
        invalid_max_socialize_losses_mr_decrease!(),
    );

    params.limits_params.min_order_usd_value = min_order_usd_value;
    params.limits_params.max_pending_orders = max_pending_orders;
    params.limits_params.max_open_interest = max_open_interest;
    params.limits_params.max_open_interest_threshold = max_open_interest_threshold;
    params.limits_params.max_open_interest_position_percent = max_open_interest_position_percent;
    params.limits_params.max_book_index_spread = max_book_index_spread;
    params.limits_params.max_index_twap_divergence = max_index_twap_divergence;
    params.limits_params.max_bad_debt = max_bad_debt;
    params.limits_params.max_socialize_losses_mr_decrease = max_socialize_losses_mr_decrease;
    events::e49(
        *ch_id,
        min_order_usd_value,
        max_pending_orders,
        max_open_interest,
        max_open_interest_threshold,
        max_open_interest_position_percent,
        max_book_index_spread,
        max_index_twap_divergence,
        max_bad_debt,
        max_socialize_losses_mr_decrease,
    )
}

public(package) fun set_base_oracle_params(
    params: &mut MarketParams,
    registry_config: &Config,
    ch_id: &ID,
    storage_id: u32,
    source_id: Option<u16>,
    oracle_tolerance: Option<u64>,
) {
    let source_id = option_u16_or(&source_id, params.core_params.base_source_id);
    let oracle_tolerance = option_u64_or(&oracle_tolerance, params.core_params.base_pfs_tolerance);
    assert!(
        oracle_tolerance >= registry_config.min_oracle_tolerance(),
        invalid_oracle_tolerance!(),
    );
    params.core_params.base_storage_id = storage_id;
    params.core_params.base_source_id = source_id;
    params.core_params.base_pfs_tolerance = oracle_tolerance;
    events::e47(*ch_id, storage_id, source_id, oracle_tolerance)
}

public(package) fun set_collateral_oracle_params(
    params: &mut MarketParams,
    registry_config: &Config,
    ch_id: &ID,
    storage_id: u32,
    source_id: Option<u16>,
    oracle_tolerance: Option<u64>,
) {
    let source_id = option_u16_or(&source_id, params.core_params.collateral_source_id);
    let oracle_tolerance = option_u64_or(
        &oracle_tolerance,
        params.core_params.collateral_pfs_tolerance,
    );
    assert!(
        oracle_tolerance >= registry_config.min_oracle_tolerance(),
        invalid_oracle_tolerance!(),
    );
    params.core_params.collateral_storage_id = storage_id;
    params.core_params.collateral_source_id = source_id;
    params.core_params.collateral_pfs_tolerance = oracle_tolerance;
    events::e48(*ch_id, storage_id, source_id, oracle_tolerance)
}

fun create_market_params(
    registry_config: &Config,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
    base_storage_id: u32,
    collateral_storage_id: u32,
    base_source_id: u16,
    collateral_source_id: u16,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
    maker_fee: u256,
    taker_fee: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    lot_size: u64,
    tick_size: u64,
    scaling_factor: u256,
): MarketParams {
    MarketParams {
        core_params: CoreParams {
            base_storage_id,
            collateral_storage_id,
            base_source_id,
            collateral_source_id,
            base_pfs_tolerance: 10_000,
            collateral_pfs_tolerance: 30_000,
            lot_size,
            tick_size,
            scaling_factor,
            collateral_haircut: 0,
            margin_ratio_initial,
            margin_ratio_maintenance,
        },
        fees_params: FeesParams {
            maker_fee,
            taker_fee,
            liquidation_fee,
            insurance_fund_fee,
            priority_taker_fee: option::some(1_000_000_000_000_000),
        },
        twap_params: TwapParams {
            funding_frequency_ms,
            funding_period_ms,
            premium_twap_frequency_ms,
            premium_twap_period_ms,
            spread_twap_frequency_ms,
            spread_twap_period_ms,
        },
        limits_params: LimitsParams {
            min_order_usd_value: registry_config.low_min_order_usd_value(),
            max_pending_orders: registry_config.up_max_pending_orders(),
            max_open_interest: ifixed::from_u64(0xffff_ffff_ffff_ffff),
            max_open_interest_threshold: ifixed::from_u64(0xffff_ffff_ffff_ffff),
            max_open_interest_position_percent: 200_000_000_000_000_000, // 20%
            max_book_index_spread: ifixed::from_u64fraction(5, 100),
            max_index_twap_divergence: ifixed::from_u64fraction(5, 100),
            max_bad_debt: 0,
            max_socialize_losses_mr_decrease: 0,
        },
    }
}

fun create_market_state(
    now: u64,
): MarketState {
    MarketState {
        cum_funding_rate_long: 0,
        cum_funding_rate_short: 0,
        funding_last_upd_ms: now,
        premium_twap: 0,
        premium_twap_last_upd_ms: now,
        spread_twap: 0,
        spread_twap_last_upd_ms: now,
        open_interest: 0,
        fees_accrued: 0,
    }
}

public(package) fun add_to_open_interest(
    market_state: &mut MarketState,
    delta: u256,
) {
    market_state.open_interest = ifixed::add(market_state.open_interest, delta)
}

public(package) fun add_fees_accrued_usd(
    state: &mut MarketState,
    fees: u256,
    collateral_price: u256
) {
    state.fees_accrued = ifixed::add(state.fees_accrued, ifixed::div(fees, collateral_price))
}

public(package) fun sub_fees_accrued(state: &mut MarketState, fees: u256) {
    state.fees_accrued = ifixed::sub(state.fees_accrued, fees)
}

public(package) fun try_update_fundings_and_twaps(
    params: &MarketParams,
    state: &mut MarketState,
    now: u64,
    index_price: u256,
    book_price: u256,
    ch_id: &ID
) {
    let clipped_book_price = clip_max_book_index_spread(params, book_price, index_price);
    if (now >= state.premium_twap_last_upd_ms + params.twap_params.premium_twap_frequency_ms) {
        state.update_premium_twap(params, index_price, book_price, clipped_book_price, now, ch_id)
    };
    if (now >= state.spread_twap_last_upd_ms + params.twap_params.spread_twap_frequency_ms) {
        state.update_spread_twap(params, index_price, book_price, clipped_book_price, now, ch_id)
    };
    try_update_fundings(params, state, now, ch_id)
}

/// The index price plus the premium that would still be paid as funding until the next
/// funding update, as a fraction of the funding period.
public fun calculate_funding_price(
    market_state: &MarketState,
    market_params: &MarketParams,
    index_price: u256,
    now: u64
): u256 {
    let next_update_ms = next_funding_update_time(
        market_state.funding_last_upd_ms,
        market_params.twap_params.funding_frequency_ms,
    );
    let remaining_period_fraction = ifixed::from_u64fraction(
        now.max(next_update_ms) - now,
        market_params.twap_params.funding_period_ms,
    );
    let premium_twap = market_state.premium_twap;
    ifixed::add(index_price, ifixed::mul(premium_twap, remaining_period_fraction))
}

/// Socializes bad debt by moving the cumulative funding rate of one side against it.
public(package) fun add_bad_debt_to_market(
    market_state: &mut MarketState,
    ch_id: &ID,
    add_to_long: bool,
    bad_debt_usd: u256,
    delta: u256,
) {
    if (add_to_long) {
        market_state.cum_funding_rate_long = ifixed::add(market_state.cum_funding_rate_long, delta)
    } else {
        market_state.cum_funding_rate_short = ifixed::sub(
            market_state.cum_funding_rate_short,
            delta,
        )
    };
    events::e26(
        *ch_id,
        bad_debt_usd,
        delta,
        add_to_long,
        market_state.cum_funding_rate_long,
        market_state.cum_funding_rate_short,
    )
}

/// Clamps `book` to `index * (1 +/- max_book_index_spread)`.
public fun clip_max_book_index_spread(params: &MarketParams, book: u256, index: u256): u256 {
    assert!(index != 0, bad_index_price!());
    let max_spread = ifixed::mul(index, params.limits_params.max_book_index_spread);
    let upper_bound = ifixed::add(index, max_spread);
    let lower_bound = ifixed::sub(index, max_spread);
    if (ifixed::greater_than(book, upper_bound)) {
        upper_bound
    } else if (ifixed::less_than(book, lower_bound)) {
        lower_bound
    } else {
        book
    }
}

public fun assert_index_twap_divergence_within_limit(
    params: &MarketParams,
    index_price: u256,
    index_twap_price: u256,
) {
    let max_divergence = ifixed::mul(
        index_twap_price,
        params.limits_params.max_index_twap_divergence,
    );
    assert!(
        ifixed::less_than_eq(
            ifixed::abs(ifixed::sub(index_price, index_twap_price)),
            max_divergence,
        ),
        index_twap_divergence!(),
    )
}

public(package) fun try_update_fundings(
    params: &MarketParams,
    state: &mut MarketState,
    now: u64,
    ch_id: &ID
) {
    if (
        !is_time_to_update(now, state.funding_last_upd_ms, params.twap_params.funding_frequency_ms)
    ) {
        return
    };
    let period_adjustment = funding_period_adjustment(
        now,
        state.funding_last_upd_ms,
        params.twap_params.funding_frequency_ms,
        params.twap_params.funding_period_ms,
    );
    let funding_rate = ifixed::mul(state.premium_twap, period_adjustment);
    state.cum_funding_rate_long = ifixed::add(state.cum_funding_rate_long, funding_rate);
    state.cum_funding_rate_short = ifixed::add(state.cum_funding_rate_short, funding_rate);
    state.funding_last_upd_ms = now;
    events::e14(
        *ch_id,
        state.cum_funding_rate_long,
        state.cum_funding_rate_short,
        state.funding_last_upd_ms,
    )
}

fun update_premium_twap(
    state: &mut MarketState,
    params: &MarketParams,
    index_price: u256,
    actual_book_price: u256,
    clipped_book_price: u256,
    now: u64,
    ch_id: &ID
) {
    state.premium_twap = update_twap(
        ifixed::sub(clipped_book_price, index_price),
        state.premium_twap,
        now,
        state.premium_twap_last_upd_ms,
        params.twap_params.premium_twap_period_ms,
    );
    state.premium_twap_last_upd_ms = now;
    events::e12(
        *ch_id,
        actual_book_price,
        clipped_book_price,
        index_price,
        state.premium_twap,
        state.premium_twap_last_upd_ms,
    )
}

fun update_spread_twap(
    state: &mut MarketState,
    params: &MarketParams,
    index_price: u256,
    actual_book_price: u256,
    clipped_book_price: u256,
    now: u64,
    ch_id: &ID
) {
    state.spread_twap = update_twap(
        ifixed::sub(clipped_book_price, index_price),
        state.spread_twap,
        now,
        state.spread_twap_last_upd_ms,
        params.twap_params.spread_twap_period_ms,
    );
    state.spread_twap_last_upd_ms = now;
    events::e13(
        *ch_id,
        actual_book_price,
        clipped_book_price,
        index_price,
        state.spread_twap,
        state.spread_twap_last_upd_ms,
    )
}

/// Time-weighted average of the new sample `price_now` (weighted by the time elapsed since the
/// last update) and `last_twap` (weighted by the rest of the TWAP period). Both weights are at
/// least 1 ms.
///
/// Prices are signed IFixed values (two's complement), so the average is computed on magnitudes:
/// `(x ^ MAX_U256) + 1` is the magnitude of a negative `x`, and `((m ^ (2^255 - 1)) + 1) ^ 2^255`
/// negates a magnitude `m` (mapping 0 to 0).
public fun update_twap(
    price_now: u256,
    last_twap: u256,
    time_now: u64,
    last_twap_ts: u64,
    twap_period_ms: u64,
): u256 {
    let elapsed_ms;
    if (time_now <= last_twap_ts) {
        elapsed_ms = 1;
    } else {
        elapsed_ms = time_now - last_twap_ts;
    };
    let remaining_ms;
    if (elapsed_ms >= twap_period_ms) {
        remaining_ms = 1;
    } else {
        remaining_ms = twap_period_ms - elapsed_ms;
    };

    let price_is_neg =
        price_now >= 0x8000000000000000000000000000000000000000000000000000000000000000;
    let twap_is_neg =
        last_twap >= 0x8000000000000000000000000000000000000000000000000000000000000000;
    let weighted_price;
    if (price_is_neg) {
        weighted_price =
            ((price_now ^ 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1)
                * (elapsed_ms as u256);
    } else {
        weighted_price = price_now * (elapsed_ms as u256);
    };
    let weighted_twap;
    if (twap_is_neg) {
        weighted_twap =
            ((last_twap ^ 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1)
                * (remaining_ms as u256);
    } else {
        weighted_twap = last_twap * (remaining_ms as u256);
    };

    // Same sign: add the magnitudes and keep the sign.
    if (price_is_neg == twap_is_neg) {
        if (price_is_neg) {
            return ((weighted_price + weighted_twap) / ((elapsed_ms + remaining_ms) as u256)
                ^ 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1
                ^ 0x8000000000000000000000000000000000000000000000000000000000000000
        };
        return (weighted_price + weighted_twap) / ((elapsed_ms + remaining_ms) as u256)
    };
    // Opposite signs: subtract the smaller magnitude; the result has the sign of the larger one.
    if (weighted_price >= weighted_twap) {
        if (price_is_neg) {
            return ((weighted_price - weighted_twap) / ((elapsed_ms + remaining_ms) as u256)
                ^ 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1
                ^ 0x8000000000000000000000000000000000000000000000000000000000000000
        };
        return (weighted_price - weighted_twap) / ((elapsed_ms + remaining_ms) as u256)
    };
    if (twap_is_neg) {
        return ((weighted_twap - weighted_price) / ((elapsed_ms + remaining_ms) as u256)
            ^ 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1
            ^ 0x8000000000000000000000000000000000000000000000000000000000000000
    };
    (weighted_twap - weighted_price) / ((elapsed_ms + remaining_ms) as u256)
}

public fun is_time_to_update(
    now: u64,
    last_upd_ms: u64,
    frequency_ms: u64
): bool {
    now >= next_funding_update_time(last_upd_ms, frequency_ms)
}

/// Updates happen on multiples of `frequency_ms`: this is the start of the interval after the one
/// containing `last_upd_ms`.
public fun next_funding_update_time(last_upd_ms: u64, frequency_ms: u64): u64 {
    let offset_in_interval = last_upd_ms % frequency_ms;
    last_upd_ms - offset_in_interval + frequency_ms
}

/// Fraction of the funding period covered by the intervals elapsed since the last update, catching
/// up at most 3 missed intervals at once.
public fun funding_period_adjustment(
    now: u64,
    funding_last_upd_ms: u64,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
): u256 {
    let elapsed_intervals = now / funding_frequency_ms - funding_last_upd_ms / funding_frequency_ms;
    let elapsed_intervals = if (elapsed_intervals > 3) 3 else elapsed_intervals;
    let frequency = ifixed::from_u64(funding_frequency_ms);
    let period = ifixed::from_u64(funding_period_ms);
    ifixed::div(ifixed::mul(ifixed::from_u64(elapsed_intervals), frequency), period)
}

public fun margin_ratio_initial(market_params: &MarketParams): u256 {
    market_params.core_params.margin_ratio_initial
}

public fun margin_ratio_maintenance(market_params: &MarketParams): u256 {
    market_params.core_params.margin_ratio_maintenance
}

public fun funding_params(market_params: &MarketParams): (u64, u64) {
    (market_params.twap_params.funding_frequency_ms, market_params.twap_params.funding_period_ms)
}

public fun premium_twap_params(market_params: &MarketParams): (u64, u64) {
    (
        market_params.twap_params.premium_twap_frequency_ms,
        market_params.twap_params.premium_twap_period_ms,
    )
}

public fun spread_twap_params(market_params: &MarketParams): (u64, u64) {
    (
        market_params.twap_params.spread_twap_frequency_ms,
        market_params.twap_params.spread_twap_period_ms,
    )
}

public fun priority_taker_fee(market_params: &MarketParams): Option<u256> {
    market_params.fees_params.priority_taker_fee
}

public fun resolve_priority_taker_fee(priority_taker_fee: Option<u256>): u256 {
    assert!(priority_taker_fee.is_some(), priority_gas_price_not_allowed!());
    *priority_taker_fee.borrow()
}

public fun maker_fee(market_params: &MarketParams): u256 {
    market_params.fees_params.maker_fee
}

public fun taker_fee(market_params: &MarketParams): u256 {
    market_params.fees_params.taker_fee
}

public fun maker_taker_fees(market_params: &MarketParams): (u256, u256) {
    (market_params.fees_params.maker_fee, market_params.fees_params.taker_fee)
}

public fun liquidation_fee_rates(market_params: &MarketParams): (u256, u256) {
    (market_params.fees_params.liquidation_fee, market_params.fees_params.insurance_fund_fee)
}

public fun base_storage_id(market_params: &MarketParams): u32 {
    market_params.core_params.base_storage_id
}

public fun collateral_storage_id(market_params: &MarketParams): u32 {
    market_params.core_params.collateral_storage_id
}

public fun base_source_id(market_params: &MarketParams): u16 {
    market_params.core_params.base_source_id
}

public fun collateral_source_id(market_params: &MarketParams): u16 {
    market_params.core_params.collateral_source_id
}

public fun base_pfs_tolerance(market_params: &MarketParams): u64 {
    market_params.core_params.base_pfs_tolerance
}

public fun collateral_pfs_tolerance(market_params: &MarketParams): u64 {
    market_params.core_params.collateral_pfs_tolerance
}

public fun min_order_usd_value(market_params: &MarketParams): u256 {
    market_params.limits_params.min_order_usd_value
}

public fun lot_size(market_params: &MarketParams): u64 {
    market_params.core_params.lot_size
}

public fun tick_size(market_params: &MarketParams): u64 {
    market_params.core_params.tick_size
}

public fun max_pending_orders(market_params: &MarketParams): u64 {
    market_params.limits_params.max_pending_orders
}

public fun max_open_interest(market_params: &MarketParams): u256 {
    market_params.limits_params.max_open_interest
}

public fun max_book_index_spread(market_params: &MarketParams): u256 {
    market_params.limits_params.max_book_index_spread
}

public fun max_index_twap_divergence(market_params: &MarketParams): u256 {
    market_params.limits_params.max_index_twap_divergence
}

public fun max_open_interest_position_params(market_params: &MarketParams): (u256, u256) {
    (
        market_params.limits_params.max_open_interest_threshold,
        market_params.limits_params.max_open_interest_position_percent,
    )
}

public fun max_bad_debt_thresholds(market_params: &MarketParams): (u256, u256) {
    (
        market_params.limits_params.max_bad_debt,
        market_params.limits_params.max_socialize_losses_mr_decrease,
    )
}

public fun collateral_haircut(market_params: &MarketParams): u256 {
    market_params.core_params.collateral_haircut
}

public fun scaling_factor(market_params: &MarketParams): u256 {
    market_params.core_params.scaling_factor
}

public fun base_oracle_price(
    market_params: &MarketParams,
    oracle: &PriceFeedStorage,
    clock: &Clock
): u256 {
    assert!(
        oracle.storage_id() == market_params.core_params.base_storage_id,
        invalid_base_price_feed_storage!(),
    );
    let (price, price_timestamp_ms) = oracle
        .price_feed(market_params.core_params.base_source_id)
        .price_and_timestamp_ms();
    let now = clock.timestamp_ms();
    // Stale price: older than the tolerance window (saturating at time zero).
    if (now - now.min(market_params.core_params.base_pfs_tolerance) > price_timestamp_ms) {
        abort bad_index_price!()
    };
    (price as u256)
}

public fun base_oracle_price_and_twap_price(
    market_params: &MarketParams,
    oracle: &PriceFeedStorage,
    clock: &Clock
): (u256, u256) {
    assert!(
        oracle.storage_id() == market_params.core_params.base_storage_id,
        invalid_base_price_feed_storage!(),
    );
    let feed = oracle.price_feed(market_params.core_params.base_source_id);
    let (price, price_timestamp_ms) = feed.price_and_timestamp_ms();
    let twap_price = feed.twap_price();
    let now = clock.timestamp_ms();
    if (now - now.min(market_params.core_params.base_pfs_tolerance) > price_timestamp_ms) {
        abort bad_index_price!()
    };
    ((price as u256), (twap_price as u256))
}

public fun collateral_oracle_price(
    market_params: &MarketParams,
    oracle: &PriceFeedStorage,
    clock: &Clock
): u256 {
    assert!(
        oracle.storage_id() == market_params.core_params.collateral_storage_id,
        invalid_collateral_price_feed_storage!(),
    );
    let feed = oracle.price_feed(market_params.core_params.collateral_source_id);
    let (price, price_timestamp_ms) = feed.price_and_timestamp_ms();
    let twap_price = feed.twap_price();
    let now = clock.timestamp_ms();
    if (now - now.min(market_params.core_params.collateral_pfs_tolerance) > price_timestamp_ms) {
        abort bad_index_price!()
    };
    let (price, twap_price) = ((price as u256), (twap_price as u256));
    assert_index_twap_divergence_within_limit(market_params, price, twap_price);
    price
}

public fun cum_funding_rates(market_state: &MarketState): (u256, u256) {
    (market_state.cum_funding_rate_long, market_state.cum_funding_rate_short)
}

public fun funding_last_upd_ms(market_state: &MarketState): u64 {
    market_state.funding_last_upd_ms
}

public fun twap_last_upd_ms(market_state: &MarketState): (u64, u64) {
    (market_state.premium_twap_last_upd_ms, market_state.spread_twap_last_upd_ms)
}

public fun premium_twap(market_state: &MarketState): u256 {
    market_state.premium_twap
}

public fun spread_twap(market_state: &MarketState): u256 {
    market_state.spread_twap
}

public fun open_interest(market_state: &MarketState): u256 {
    market_state.open_interest
}

public fun fees_accrued(state: &MarketState): u256 {
    state.fees_accrued
}

/// Median of the funding price, the spread-adjusted index TWAP and the book price.
public fun calculate_mark_price(
    market_state: &MarketState,
    market_params: &MarketParams,
    index_twap_price: u256,
    book_price: u256,
    now: u64
): u256 {
    let funding_price = calculate_funding_price(market_state, market_params, index_twap_price, now);
    let spread_price = ifixed::add(index_twap_price, market_state.spread_twap());
    ifixed::max(
        ifixed::min(spread_price, funding_price),
        ifixed::min(ifixed::max(spread_price, funding_price), book_price),
    )
}

public(package) fun assert_margin_ratios(
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
) {
    assert!(
        ifixed::less_than_eq(margin_ratio_initial, 1_000_000_000_000_000_000)
            && ifixed::less_than(margin_ratio_maintenance, margin_ratio_initial)
            && ifixed::greater_than(margin_ratio_maintenance, 0),
        invalid_margin_ratios!(),
    )
}

fun assert_funding_parameters(
    registry_config: &Config,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
) {
    assert!(
        funding_period_ms >= registry_config.min_funding_period_ms()
            && funding_period_ms <= registry_config.max_funding_period_ms()
            && funding_frequency_ms >= registry_config.min_funding_frequency_ms()
            && funding_period_ms > funding_frequency_ms
            && funding_period_ms % funding_frequency_ms == 0,
        invalid_funding_parameters!(),
    );
    assert!(
        premium_twap_frequency_ms >= registry_config.min_premium_twap_frequency_ms()
            && premium_twap_period_ms >= registry_config.min_premium_twap_period_ms()
            && premium_twap_period_ms > premium_twap_frequency_ms,
        invalid_twap_parameters!(),
    )
}

fun assert_spread_twap_parameters(
    registry_config: &Config,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
) {
    assert!(
        spread_twap_frequency_ms >= registry_config.min_spread_twap_frequency_ms()
            && spread_twap_period_ms >= registry_config.min_spread_twap_period_ms()
            && spread_twap_period_ms > spread_twap_frequency_ms,
        invalid_twap_parameters!(),
    )
}

fun assert_priority_taker_fee(registry_config: &Config, priority_taker_fee: Option<u256>) {
    if (priority_taker_fee.is_none()) {
        return
    };
    let fee = *priority_taker_fee.borrow();
    assert!(
        ifixed::greater_than_eq(fee, 0)
            && ifixed::less_than_eq(fee, registry_config.max_abs_taker_fee()),
        invalid_priority_taker_fee!(),
    )
}

/// Fees are bounded in absolute value; a negative fee (rebate) on one side must be covered by a
/// non-negative fee on the other side that is at least as large.
fun assert_market_fees(registry_config: &Config, maker_fee: u256, taker_fee: u256) {
    assert!(
        ifixed::less_than_eq(ifixed::abs(maker_fee), registry_config.max_abs_maker_fee())
            && ifixed::less_than_eq(ifixed::abs(taker_fee), registry_config.max_abs_taker_fee()),
        invalid_market_fees!(),
    );
    assert!(
        !ifixed::is_neg(maker_fee)
            || (
                !ifixed::is_neg(taker_fee)
                    && ifixed::less_than_eq(ifixed::abs(maker_fee), taker_fee)
            ),
        negative_maker_fee_not_covered!(),
    );
    assert!(
        !ifixed::is_neg(taker_fee)
            || (
                !ifixed::is_neg(maker_fee)
                    && ifixed::less_than_eq(ifixed::abs(taker_fee), maker_fee)
            ),
        negative_taker_fee_not_covered!(),
    )
}

fun assert_liquidation_fees(
    registry_config: &Config,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
) {
    assert!(
        !ifixed::is_neg(liquidation_fee)
            && ifixed::less_than_eq(liquidation_fee, registry_config.max_liquidation_fee())
            && !ifixed::is_neg(insurance_fund_fee)
            && ifixed::less_than_eq(insurance_fund_fee, registry_config.max_insurance_fund_fee()),
        invalid_liquidation_fees!(),
    )
}

public(package) fun assert_liquidation_fees_against_mmr(
    margin_ratio_maintenance: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
) {
    assert!(
        ifixed::less_than(
            ifixed::add(liquidation_fee, insurance_fund_fee),
            margin_ratio_maintenance,
        ),
        liquidation_fees_exceed_maintenance_margin_ratio!(),
    )
}

fun assert_lot_and_tick_sizes(
    lot_size: u64,
    tick_size: u64
) {
    assert!(
        lot_size > 0 && lot_size <= 1_000_000_000 && tick_size > 0 && tick_size <= 1_000_000_000,
        invalid_lot_and_tick_sizes!(),
    )
}
