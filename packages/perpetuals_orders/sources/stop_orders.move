// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals_orders::stop_orders;

use authority_cap::authority::AuthorityCap;
use haneul::balance::Balance;
use haneul::bcs;
use haneul::clock::Clock;
use haneul::coin::{Self, Coin};
use haneul::haneul::HANEUL;
use haneul::hash;
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::{Account, IntegratorInfo};
use perpetuals::authority::{Self, ACCOUNT};
use perpetuals::clearing_house::{ClearingHouse, Executor, SessionSummary};
use perpetuals_orders::events;
use perpetuals_orders::extension;
use perpetuals::market;
use perpetuals::registry::Registry;

// === Errors and constants ===

const EStopOrderTicketExpired: u64 = 6200;
const EStopOrderConditionsViolated: u64 = 6201;
const EWrongOrderDetails: u64 = 6202;
const ENotEnoughGasForStopOrder: u64 = 6203;
const EInvalidExecutorForStopOrder: u64 = 6204;
const EInvalidStopOrderType: u64 = 6205;
const EInvalidPositionForSltp: u64 = 6206;
const EInvalidStopOrderTriggerPriceType: u64 = 6207;
const EWrongStopOrderTypeForExecution: u64 = 6208;
const EStopOrderWithoutEconomicActivity: u64 = 6209;
const EInvalidStopOrderGasPrice: u64 = 6210;

// === Types ===

public struct StopOrderTicket<phantom T> has key, store {
    id: UID,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: Balance<HANEUL>,
    account_id: u64,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
}

// === Functions ===

public fun create_stop_order_ticket<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: Coin<HANEUL>,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext,
): ID {
    account.assert_authority_cap_is_valid(cap);
    registry.assert_package_version();
    // 0: stop loss / take profit on the current position, 1: standalone stop order.
    assert!(stop_order_type < 2, EInvalidStopOrderType);
    assert!(gas.value() >= registry.stop_order_geunhwa_cost(), ENotEnoughGasForStopOrder);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();

    let account_id = account.account_id();
    let gas_amount = gas.value();
    let ticket = StopOrderTicket<T> {
        id: object::new(ctx),
        executors,
        execution_domain,
        gas: gas.into_balance(),
        account_id,
        stop_order_type,
        encrypted_details,
    };
    events::created_stop_order_ticket<T>(
        ticket.id.to_inner(),
        account_id,
        executors,
        execution_domain,
        gas_amount,
        stop_order_type,
        ticket.encrypted_details,
    );
    account.add_order_ticket_as_extension(&extension::witness(), registry, ticket)
}

public fun cancel<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    ticket_id: ID,
    ctx: &mut TxContext
): Coin<HANEUL> {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(ticket_id);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    let StopOrderTicket<T> {
        id,
        executors: _,
        execution_domain: _,
        gas,
        account_id,
        stop_order_type: _,
        encrypted_details: _,
    } = account.remove_order_ticket_as_extension(&extension::witness(), registry, ticket_id);
    events::deleted_stop_order_ticket<T>(id.to_inner(), account_id, ctx.sender());
    id.delete();
    coin::from_balance(gas, ctx)
}

public fun cancel_stop_order_ticket<T>(
    account: &mut Account<T>,
    registry: &Registry,
    ticket_id: ID,
    executor: &Executor,
    ctx: &mut TxContext
): Coin<HANEUL> {
    registry.assert_package_version();
    let executor_address = executor.executor_sender();
    account.assert_order_ticket_exists(ticket_id);
    let ticket: StopOrderTicket<T> = account.remove_order_ticket_as_extension(&extension::witness(), registry, ticket_id);
    ticket.assert_valid_ticket_executor(executor);
    let StopOrderTicket {
        id,
        executors: _,
        execution_domain: _,
        gas,
        account_id,
        stop_order_type: _,
        encrypted_details: _,
    } = ticket;
    events::deleted_stop_order_ticket<T>(id.to_inner(), account_id, executor_address);
    id.delete();
    coin::from_balance(gas, ctx)
}

public fun edit_stop_order_ticket_details<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(ticket_id);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    account.borrow_mut_order_ticket_as_extension<_, _, StopOrderTicket<T>>(&extension::witness(), registry, ticket_id).encrypted_details =
        encrypted_details;
    events::edited_stop_order_ticket_details<T>(ticket_id, account.account_id(), encrypted_details)
}

public fun edit_stop_order_ticket_executors<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    ticket_id: ID,
    executors: vector<address>,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(ticket_id);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    account.borrow_mut_order_ticket_as_extension<_, _, StopOrderTicket<T>>(&extension::witness(), registry, ticket_id).executors =
        executors;
    events::edited_stop_order_ticket_executors<T>(ticket_id, account.account_id(), executors)
}

/// Executes a stop loss / take profit ticket: closes (part of) the account's position once the
/// trigger price crosses one of the committed levels.
public fun place_stop_order_sltp<T>(
    mut clearing_house: ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    registry: &Registry,
    ticket_id: ID,
    account: &mut Account<T>,
    expire_timestamp: Option<u64>,
    is_limit_order: bool,
    trigger_price_type: u8,
    stop_loss_price: Option<u256>,
    take_profit_price: Option<u256>,
    position_is_ask: bool,
    size: u64,
    price: u64,
    order_type: u64,
    salt: vector<u8>,
    integrator_info: Option<IntegratorInfo>,
    executor: &Executor,
    ctx: &mut TxContext
): (SessionSummary, Coin<HANEUL>, ClearingHouse<T>) {
    clearing_house.assert_package_version();
    clearing_house.assert_market_is_not_paused();
    assert!(ctx.gas_price() == ctx.reference_gas_price(), EInvalidStopOrderGasPrice);

    let (gas, encrypted_details) = consume_ticket(account, registry, ticket_id, executor, 0);
    assert_stop_order_trigger_price_type(trigger_price_type);

    // The ticket commits to blake2b256(bcs(order details) || salt).
    let mut details = vector[];
    details.append(bcs::to_bytes(&object::id(&clearing_house)));
    details.append(bcs::to_bytes(&expire_timestamp));
    details.append(bcs::to_bytes(&is_limit_order));
    details.append(bcs::to_bytes(&trigger_price_type));
    details.append(bcs::to_bytes(&stop_loss_price));
    details.append(bcs::to_bytes(&take_profit_price));
    details.append(bcs::to_bytes(&position_is_ask));
    details.append(bcs::to_bytes(&size));
    details.append(bcs::to_bytes(&price));
    details.append(bcs::to_bytes(&order_type));
    details.append(bcs::to_bytes(&integrator_info));
    details.append(salt);
    assert!(hash::blake2b256(&details) == encrypted_details, EWrongOrderDetails);

    let now = clock.timestamp_ms();
    if (expire_timestamp.is_some()) {
        assert!(now < *expire_timestamp.borrow(), EStopOrderTicketExpired)
    };
    let (index_price, index_twap_price) = market::base_oracle_price_and_twap_price(
        clearing_house.market_params(),
        base_oracle,
        clock,
    );
    let trigger_price = derive_stop_order_trigger_price(
        &mut clearing_house,
        registry,
        index_price,
        index_twap_price,
        trigger_price_type,
        now,
    );
    // For a short (ask) position the stop loss is above the price and the take profit below it;
    // the other way around for a long position.
    let stop_loss_triggered = stop_loss_price.is_some() && {
        let stop_loss_price = stop_loss_price.borrow();
        (position_is_ask && ifixed::greater_than_eq(trigger_price, *stop_loss_price))
            || (!position_is_ask && ifixed::less_than_eq(trigger_price, *stop_loss_price))
    };
    let take_profit_triggered = take_profit_price.is_some() && {
        let take_profit_price = take_profit_price.borrow();
        (position_is_ask && ifixed::less_than_eq(trigger_price, *take_profit_price))
            || (!position_is_ask && ifixed::greater_than_eq(trigger_price, *take_profit_price))
    };
    assert!(stop_loss_triggered || take_profit_triggered, EStopOrderConditionsViolated);

    let (position_base, _) = clearing_house.position(account.account_id()).base_and_quote_amounts();
    assert!(
        position_base != 0 && position_is_ask == ifixed::is_neg(position_base),
        EInvalidPositionForSltp,
    );
    // Never close more than the current position.
    let requested_size = size;
    let position_size = ifixed::abs(position_base);
    let size = requested_size.min(ifixed::to_balance(position_size, 1_000_000_000));

    let (summary, clearing_house) = run_stop_order(
        clearing_house, account, base_oracle, collateral_oracle, clock, registry, integrator_info,
        !position_is_ask, size, price, is_limit_order, order_type, true, expire_timestamp, false,
    );
    (summary, coin::from_balance(gas, ctx), clearing_house)
}

/// Executes a standalone stop ticket: places the committed order once the trigger price is at or
/// above (`ge_stop_index_price`) or at or below `stop_index_price`.
public fun place_stop_order_standalone<T>(
    mut clearing_house: ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    registry: &Registry,
    ticket_id: ID,
    account: &mut Account<T>,
    expire_timestamp: Option<u64>,
    is_limit_order: bool,
    trigger_price_type: u8,
    stop_index_price: u256,
    ge_stop_index_price: bool,
    side: bool,
    size: u64,
    price: u64,
    order_type: u64,
    reduce_only: bool,
    salt: vector<u8>,
    integrator_info: Option<IntegratorInfo>,
    executor: &Executor,
    ctx: &mut TxContext
): (SessionSummary, Coin<HANEUL>, ClearingHouse<T>) {
    clearing_house.assert_package_version();
    clearing_house.assert_market_is_not_paused();
    assert!(ctx.gas_price() == ctx.reference_gas_price(), EInvalidStopOrderGasPrice);

    let (gas, encrypted_details) = consume_ticket(account, registry, ticket_id, executor, 1);
    assert_stop_order_trigger_price_type(trigger_price_type);

    // The ticket commits to blake2b256(bcs(order details) || salt).
    let mut details = vector[];
    details.append(bcs::to_bytes(&object::id(&clearing_house)));
    details.append(bcs::to_bytes(&expire_timestamp));
    details.append(bcs::to_bytes(&is_limit_order));
    details.append(bcs::to_bytes(&trigger_price_type));
    details.append(bcs::to_bytes(&stop_index_price));
    details.append(bcs::to_bytes(&ge_stop_index_price));
    details.append(bcs::to_bytes(&side));
    details.append(bcs::to_bytes(&size));
    details.append(bcs::to_bytes(&price));
    details.append(bcs::to_bytes(&order_type));
    details.append(bcs::to_bytes(&reduce_only));
    details.append(bcs::to_bytes(&integrator_info));
    details.append(salt);
    assert!(hash::blake2b256(&details) == encrypted_details, EWrongOrderDetails);

    let now = clock.timestamp_ms();
    if (expire_timestamp.is_some()) {
        assert!(now < *expire_timestamp.borrow(), EStopOrderTicketExpired)
    };
    let (index_price, index_twap_price) = market::base_oracle_price_and_twap_price(
        clearing_house.market_params(),
        base_oracle,
        clock,
    );
    let trigger_price = derive_stop_order_trigger_price(
        &mut clearing_house,
        registry,
        index_price,
        index_twap_price,
        trigger_price_type,
        now,
    );
    assert!(
        (ge_stop_index_price && ifixed::greater_than_eq(trigger_price, stop_index_price))
            || (!ge_stop_index_price && ifixed::less_than_eq(trigger_price, stop_index_price)),
        EStopOrderConditionsViolated,
    );

    let (summary, clearing_house) = run_stop_order(
        clearing_house, account, base_oracle, collateral_oracle, clock, registry, integrator_info,
        side, size, price, is_limit_order, order_type, reduce_only, expire_timestamp, !reduce_only,
    );
    (summary, coin::from_balance(gas, ctx), clearing_house)
}

/// Removes the ticket from the account, checks its executor and type, and returns its gas and
/// commitment.
fun consume_ticket<T>(
    account: &mut Account<T>,
    registry: &Registry,
    ticket_id: ID,
    executor: &Executor,
    expected_type: u64,
): (Balance<HANEUL>, vector<u8>) {
    account.assert_order_ticket_exists(ticket_id);
    let ticket: StopOrderTicket<T> = account.remove_order_ticket_as_extension(&extension::witness(), registry, ticket_id);
    ticket.assert_valid_ticket_executor(executor);
    let StopOrderTicket {
        id,
        executors: _,
        execution_domain: _,
        gas,
        account_id,
        stop_order_type,
        encrypted_details,
    } = ticket;
    events::executed_stop_order_ticket<T>(id.to_inner(), account_id, executor.executor_sender());
    id.delete();
    assert!(stop_order_type == expected_type, EWrongStopOrderTypeForExecution);
    (gas, encrypted_details)
}

/// Places the committed order in a session of its own, which must fill or rest something.
fun run_stop_order<T>(
    clearing_house: ClearingHouse<T>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    registry: &Registry,
    integrator_info: Option<IntegratorInfo>,
    side: bool,
    size: u64,
    price: u64,
    is_limit_order: bool,
    order_type: u64,
    reduce_only: bool,
    expire_timestamp: Option<u64>,
    allocate_missing_margin: bool,
): (SessionSummary, ClearingHouse<T>) {
    let mut session = clearing_house.start_session_as_extension(
        &extension::witness(),
        registry,
        account.account_id(),
        base_oracle,
        collateral_oracle,
        false,
        integrator_info,
        clock,
    );
    if (is_limit_order) {
        let _ = session.place_limit_order(
            side,
            size,
            price,
            order_type,
            option::none(),
            reduce_only,
            expire_timestamp,
        );
    } else {
        session.place_market_order(side, size, reduce_only)
    };
    let summary = session.summary();
    assert!(
        summary.base_filled_ask() != 0
            || summary.base_filled_bid() != 0
            || summary.posted_orders() != 0,
        EStopOrderWithoutEconomicActivity,
    );
    let (clearing_house, summary) =
        session.end_session_as_extension(&extension::witness(), registry, account, allocate_missing_margin, true, false);
    (summary, clearing_house)
}

/// Trigger price types: 0 = index price, 1 = book price (index if the book is empty),
/// 2 = mark price (updates fundings and TWAPs first).
fun derive_stop_order_trigger_price<T>(
    clearing_house: &mut ClearingHouse<T>,
    registry: &Registry,
    index_price: u256,
    index_twap_price: u256,
    trigger_price_type: u8,
    now: u64
): u256 {
    assert_stop_order_trigger_price_type(trigger_price_type);
    if (trigger_price_type == 0) {
        return index_price
    };
    let book_price = clearing_house.orderbook().book_price_or_index(index_price);
    if (trigger_price_type == 1) {
        return book_price
    };
    market::assert_index_twap_divergence_within_limit(
        clearing_house.market_params(),
        index_price,
        index_twap_price,
    );
    clearing_house.update_fundings_and_twaps_as_extension(
        &extension::witness(),
        registry,
        index_price,
        book_price,
        now,
    );
    let (market_params, market_state) = clearing_house.market_objects();
    market::calculate_mark_price(market_state, market_params, index_twap_price, book_price, now)
}

fun assert_stop_order_trigger_price_type(trigger_price_type: u8) {
    assert!(trigger_price_type < 3, EInvalidStopOrderTriggerPriceType)
}

fun assert_valid_ticket_executor<T>(ticket: &StopOrderTicket<T>, executor: &Executor) {
    let executors = &ticket.executors;
    let executor_address = executor.executor_sender();
    assert!(executors.contains(&executor_address), EInvalidExecutorForStopOrder);
    assert!(
        ticket.execution_domain == executor.executor_domain(),
        EInvalidExecutorForStopOrder,
    )
}
