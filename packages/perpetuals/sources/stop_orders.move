// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::stop_orders;

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
use perpetuals::events;
use perpetuals::market;
use perpetuals::registry::Registry;

// === Errors and constants (original names from the published interface) ===

macro fun stop_order_ticket_expired(): u64 { 6200 }
macro fun stop_order_conditions_violated(): u64 { 6201 }
macro fun wrong_order_details(): u64 { 6202 }
macro fun not_enough_gas_for_stop_order(): u64 { 6203 }
macro fun invalid_executor_for_stop_order(): u64 { 6204 }
macro fun invalid_stop_order_type(): u64 { 6205 }
macro fun invalid_position_for_sltp(): u64 { 6206 }
macro fun invalid_stop_order_trigger_price_type(): u64 { 6207 }
macro fun wrong_stop_order_type_for_execution(): u64 { 6208 }
macro fun stop_order_without_economic_activity(): u64 { 6209 }
macro fun invalid_stop_order_gas_price(): u64 { 6210 }

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
    assert!(stop_order_type < 2, invalid_stop_order_type!());
    assert!(gas.value() >= registry.stop_order_geunhwa_cost(), not_enough_gas_for_stop_order!());
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
    events::e31<T>(
        ticket.id.to_inner(),
        account_id,
        executors,
        execution_domain,
        gas_amount,
        stop_order_type,
        ticket.encrypted_details,
    );
    account.add_order_ticket(ticket)
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
    } = account.remove_order_ticket(ticket_id);
    events::e33<T>(id.to_inner(), account_id, ctx.sender());
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
    let ticket: StopOrderTicket<T> = account.remove_order_ticket(ticket_id);
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
    events::e33<T>(id.to_inner(), account_id, executor_address);
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
    account.borrow_mut_order_ticket<_, StopOrderTicket<T>>(ticket_id).encrypted_details =
        encrypted_details;
    events::e34<T>(ticket_id, account.account_id(), encrypted_details)
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
    account.borrow_mut_order_ticket<_, StopOrderTicket<T>>(ticket_id).executors =
        executors;
    events::e35<T>(ticket_id, account.account_id(), executors)
}

/// Executes a stop loss / take profit ticket: closes (part of) the account's position once the
/// trigger price crosses one of the committed levels.
public fun place_stop_order_sltp<T>(
    mut clearing_house: ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
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
    assert!(ctx.gas_price() == ctx.reference_gas_price(), invalid_stop_order_gas_price!());

    let (gas, stop_order_type, encrypted_details) = {
        account.assert_order_ticket_exists(ticket_id);
        let executor_address = executor.executor_sender();
        let ticket: StopOrderTicket<T> = account.remove_order_ticket(ticket_id);
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
        events::e32<T>(id.to_inner(), account_id, executor_address);
        id.delete();
        (gas, stop_order_type, encrypted_details)
    };
    assert!(stop_order_type == 0, wrong_stop_order_type_for_execution!());
    assert_stop_order_trigger_price_type(trigger_price_type);

    // The ticket commits to blake2b256(bcs(order details) || salt). Each field goes through a
    // `bytes`/`value` binding pair and the salt is copied, mirroring the original append macro so
    // that the compiled code stays identical to the published bytecode.
    let mut details = vector[];
    let bytes = &mut details;
    let value = object::id(&clearing_house);
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = expire_timestamp;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = is_limit_order;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = trigger_price_type;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = stop_loss_price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = take_profit_price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = position_is_ask;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = size;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = order_type;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = integrator_info;
    bytes.append(bcs::to_bytes(&value));
    details.append(*&salt);
    assert!(hash::blake2b256(&details) == *&encrypted_details, wrong_order_details!());

    let now = clock.timestamp_ms();
    if (expire_timestamp.is_some()) {
        assert!(now < *expire_timestamp.borrow(), stop_order_ticket_expired!())
    };
    let (index_price, index_twap_price) = market::base_oracle_price_and_twap_price(
        clearing_house.market_params(),
        base_oracle,
        clock,
    );
    let trigger_price = derive_stop_order_trigger_price(
        &mut clearing_house,
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
    assert!(stop_loss_triggered || take_profit_triggered, stop_order_conditions_violated!());

    let (position_base, _) = clearing_house.position(account.account_id()).base_and_quote_amounts();
    assert!(
        position_base != 0 && position_is_ask == ifixed::is_neg(position_base),
        invalid_position_for_sltp!(),
    );
    // Never close more than the current position.
    let requested_size = size;
    let position_size = ifixed::abs(position_base);
    let size = requested_size.min(ifixed::to_balance(position_size, 1_000_000_000));

    let mut session = clearing_house.start_session_(
        account.account_id(),
        base_oracle,
        collateral_oracle,
        false,
        integrator_info,
        clock,
    );
    if (is_limit_order) {
        let _ = session.place_limit_order(
            !position_is_ask,
            size,
            price,
            order_type,
            option::none(),
            true,
            expire_timestamp,
        );
    } else {
        session.place_market_order(!position_is_ask, size, false)
    };
    let summary = session.summary();
    assert!(
        summary.base_filled_ask() != 0
            || summary.base_filled_bid() != 0
            || summary.posted_orders() != 0,
        stop_order_without_economic_activity!(),
    );
    let (clearing_house, summary) = session.end_session_(account, false, true, false);
    (summary, coin::from_balance(gas, ctx), clearing_house)
}

/// Executes a standalone stop ticket: places the committed order once the trigger price is at or
/// above (`ge_stop_index_price`) or at or below `stop_index_price`.
public fun place_stop_order_standalone<T>(
    mut clearing_house: ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
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
    assert!(ctx.gas_price() == ctx.reference_gas_price(), invalid_stop_order_gas_price!());

    let (gas, stop_order_type, encrypted_details) = {
        account.assert_order_ticket_exists(ticket_id);
        let ticket: StopOrderTicket<T> = account.remove_order_ticket(ticket_id);
        let executor_address = executor.executor_sender();
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
        events::e32<T>(id.to_inner(), account_id, executor_address);
        id.delete();
        (gas, stop_order_type, encrypted_details)
    };
    assert!(stop_order_type == 1, wrong_stop_order_type_for_execution!());
    assert_stop_order_trigger_price_type(trigger_price_type);

    // The ticket commits to blake2b256(bcs(order details) || salt). Each field goes through a
    // `bytes`/`value` binding pair and the salt is copied, mirroring the original append macro so
    // that the compiled code stays identical to the published bytecode.
    let mut details = vector[];
    let bytes = &mut details;
    let value = object::id(&clearing_house);
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = expire_timestamp;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = is_limit_order;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = trigger_price_type;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = stop_index_price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = ge_stop_index_price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = side;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = size;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = price;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = order_type;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = reduce_only;
    bytes.append(bcs::to_bytes(&value));
    let bytes = &mut details;
    let value = integrator_info;
    bytes.append(bcs::to_bytes(&value));
    details.append(*&salt);
    assert!(hash::blake2b256(&details) == *&encrypted_details, wrong_order_details!());

    let now = clock.timestamp_ms();
    if (expire_timestamp.is_some()) {
        assert!(now < *expire_timestamp.borrow(), stop_order_ticket_expired!())
    };
    let (index_price, index_twap_price) = market::base_oracle_price_and_twap_price(
        clearing_house.market_params(),
        base_oracle,
        clock,
    );
    let trigger_price = derive_stop_order_trigger_price(
        &mut clearing_house,
        index_price,
        index_twap_price,
        trigger_price_type,
        now,
    );
    assert!(
        (ge_stop_index_price && ifixed::greater_than_eq(trigger_price, stop_index_price))
            || (!ge_stop_index_price && ifixed::less_than_eq(trigger_price, stop_index_price)),
        stop_order_conditions_violated!(),
    );

    let mut session = clearing_house.start_session_(
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
        stop_order_without_economic_activity!(),
    );
    let (clearing_house, summary) = session.end_session_(account, !reduce_only, true, false);
    (summary, coin::from_balance(gas, ctx), clearing_house)
}

/// Trigger price types: 0 = index price, 1 = book price (index if the book is empty),
/// 2 = mark price (updates fundings and TWAPs first).
fun derive_stop_order_trigger_price<T>(
    clearing_house: &mut ClearingHouse<T>,
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
    let ch_id = &object::id(clearing_house);
    let (market_params, market_state) = clearing_house.borrow_mut_market_objects();
    market::assert_index_twap_divergence_within_limit(market_params, index_price, index_twap_price);
    market::try_update_fundings_and_twaps(
        market_params,
        market_state,
        now,
        index_price,
        book_price,
        ch_id,
    );
    market::calculate_mark_price(market_state, market_params, index_twap_price, book_price, now)
}

fun assert_stop_order_trigger_price_type(trigger_price_type: u8) {
    assert!(trigger_price_type < 3, invalid_stop_order_trigger_price_type!())
}

fun assert_valid_ticket_executor<T>(ticket: &StopOrderTicket<T>, executor: &Executor) {
    let executors = &ticket.executors;
    let executor_address = executor.executor_sender();
    assert!(executors.contains(&executor_address), invalid_executor_for_stop_order!());
    assert!(
        ticket.execution_domain == executor.executor_domain(),
        invalid_executor_for_stop_order!(),
    )
}
