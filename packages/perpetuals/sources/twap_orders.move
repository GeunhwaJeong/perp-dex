// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module perpetuals::twap_orders;

use authority_cap::authority::AuthorityCap;
use haneul::balance::{Self, Balance};
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
use perpetuals::registry::Registry;
use std::bcs;

// === Errors and constants (original names from the published interface) ===

macro fun invalid_order_details(): u64 { 6300 }
macro fun twap_order_ticket_expired(): u64 { 6301 }
macro fun twap_order_amount_uncertainty_violated(): u64 { 6302 }
macro fun twap_order_execution_gap_violated(): u64 { 6303 }
macro fun twap_order_fully_executed(): u64 { 6304 }
macro fun twap_order_executed_after_retry_time(): u64 { 6305 }
macro fun twap_order_invalid_executor(): u64 { 6306 }
macro fun twap_order_cannot_edit_active_order(): u64 { 6307 }
macro fun twap_order_not_completed(): u64 { 6308 }
macro fun twap_order_invalid_clearing_house(): u64 { 6309 }
macro fun twap_order_first_run_expired(): u64 { 6310 }
macro fun invalid_twap_order_gas_price(): u64 { 6311 }
macro fun twap_order_invalid_lot_size(): u64 { 6312 }

// === Types ===

public struct TWAPOrderDetails has drop {
    first_run_expire_timestamp: Option<u64>,
    expire_timestamp: Option<u64>,
    execution_gap_ms: u64,
    execution_time_uncertainty_ms: u64,
    chunks_amount: u64,
    small_tail_merge_threshold_bps: u64,
    time_for_retry_ms: u64,
    amount_uncertainty_bps: u64,
    max_one_execution_amount_bps: u64,
    side: bool,
    size: u64,
    max_slippage_bps: u64,
    reduce_only: bool,
    integrator_info: Option<IntegratorInfo>,
    salt: vector<u8>,
}

public struct TWAPOrderTicket<phantom T> has key, store {
    id: UID,
    clearing_house_id: ID,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: Balance<HANEUL>,
    gas_execution_budget: u64,
    account_id: u64,
    encrypted_details: vector<u8>,
    processed_amount: u64,
    scheduled_amount: u64,
    last_attempt_timestamp_ms: u64,
    retry_anchor_timestamp_ms: u64,
    last_execution_timestamp_ms: u64,
    paid_execution_gas: u64,
}

// === Functions ===

public fun new_details(
    first_run_expire_timestamp: Option<u64>,
    expire_timestamp: Option<u64>,
    execution_gap_ms: u64,
    execution_time_uncertainty_ms: u64,
    chunks_amount: u64,
    small_tail_merge_threshold_bps: u64,
    time_for_retry_ms: u64,
    amount_uncertainty_bps: u64,
    max_one_execution_amount_bps: u64,
    side: bool,
    size: u64,
    max_slippage_bps: u64,
    reduce_only: bool,
    integrator_info: Option<IntegratorInfo>,
    salt: vector<u8>
): TWAPOrderDetails {
    assert!(size != 0 && chunks_amount != 0 && size >= chunks_amount, invalid_order_details!());
    TWAPOrderDetails {
        first_run_expire_timestamp,
        expire_timestamp,
        execution_gap_ms,
        execution_time_uncertainty_ms,
        chunks_amount,
        small_tail_merge_threshold_bps,
        time_for_retry_ms,
        amount_uncertainty_bps,
        max_one_execution_amount_bps,
        side,
        size,
        max_slippage_bps,
        reduce_only,
        integrator_info,
        salt,
    }
}

/// Size of one chunk, rounded down to the lot size.
public(package) fun target_chunk_amount(
    new_details: &TWAPOrderDetails,
    lot_size: u64,
): u64 {
    new_details.size / lot_size / new_details.chunks_amount * lot_size
}

public fun create_twap_order_ticket<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    clearing_house: &ClearingHouse<T>,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: Coin<HANEUL>,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext
): ID {
    clearing_house.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();

    let clearing_house_id = object::id(clearing_house);
    let account_id = account.account_id();
    let gas_amount = gas.value();
    let ticket = TWAPOrderTicket<T> {
        id: object::new(ctx),
        clearing_house_id,
        executors,
        execution_domain,
        gas: gas.into_balance(),
        gas_execution_budget: gas_amount,
        paid_execution_gas: 0,
        account_id,
        encrypted_details,
        processed_amount: 0,
        scheduled_amount: 0,
        last_attempt_timestamp_ms: 0,
        retry_anchor_timestamp_ms: 0,
        last_execution_timestamp_ms: 0,
    };
    events::e36<T>(
        ticket.id.to_inner(),
        clearing_house_id,
        account_id,
        executors,
        execution_domain,
        gas_amount,
        ticket.encrypted_details,
    );
    account.add_order_ticket(ticket)
}

public fun cancel<T>(
    account: &mut Account<T>,
    clearing_house: &mut ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    twap_order_ticket_id: ID,
    clock: &Clock,
    executor: &Executor,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    clearing_house.assert_package_version();
    account.assert_order_ticket_exists(twap_order_ticket_id);
    let ticket: TWAPOrderTicket<T> = account.remove_order_ticket(twap_order_ticket_id);
    let executor_address = executor.executor_sender();
    ticket.assert_valid_ticket_executor(executor);
    ticket.assert_valid_ticket_clearing_house(object::id(clearing_house));

    // A partially executed order releases the collateral it no longer needs (not while paused).
    let deallocated_collateral = if (
        ticket.processed_amount != 0 && !clearing_house.is_market_paused()
    ) {
        clearing_house.deallocate_collateral_internal(
            account,
            base_oracle,
            collateral_oracle,
            option::none(),
            clock,
        )
    } else {
        0
    };
    events::e39<T>(
        ticket.id.to_inner(),
        ticket.account_id,
        executor_address,
        deallocated_collateral,
        ticket.processed_amount != 0,
    );

    let TWAPOrderTicket {
        id,
        clearing_house_id: _,
        executors: _,
        execution_domain: _,
        gas,
        gas_execution_budget: _,
        account_id,
        encrypted_details: _,
        processed_amount: _,
        scheduled_amount: _,
        last_attempt_timestamp_ms: _,
        retry_anchor_timestamp_ms: _,
        last_execution_timestamp_ms: _,
        paid_execution_gas: _,
    } = ticket;
    events::e40<T>(id.to_inner(), account_id, executor_address);
    id.delete();
    coin::from_balance(gas, ctx)
}

public fun user_cancel_twap_order<T, Role>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, Role>,
    clearing_house: &mut ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    twap_order_ticket_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    clearing_house.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(twap_order_ticket_id);
    let ticket: TWAPOrderTicket<T> = account.remove_order_ticket(twap_order_ticket_id);
    let sender = ctx.sender();
    ticket.assert_valid_ticket_clearing_house(object::id(clearing_house));

    let deallocated_collateral = if (
        ticket.processed_amount != 0 && !clearing_house.is_market_paused()
    ) {
        clearing_house.deallocate_collateral_internal(
            account,
            base_oracle,
            collateral_oracle,
            option::none(),
            clock,
        )
    } else {
        0
    };
    events::e39<T>(
        ticket.id.to_inner(),
        ticket.account_id,
        sender,
        deallocated_collateral,
        ticket.processed_amount != 0,
    );

    let TWAPOrderTicket {
        id,
        clearing_house_id: _,
        executors: _,
        execution_domain: _,
        gas,
        gas_execution_budget: _,
        account_id,
        encrypted_details: _,
        processed_amount: _,
        scheduled_amount: _,
        last_attempt_timestamp_ms: _,
        retry_anchor_timestamp_ms: _,
        last_execution_timestamp_ms: _,
        paid_execution_gas: _,
    } = ticket;
    events::e40<T>(id.to_inner(), account_id, sender);
    id.delete();
    coin::from_balance(gas, ctx)
}

public fun finalize<T>(
    account: &mut Account<T>,
    clearing_house: &mut ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    twap_order_ticket_id: ID,
    new_details: &TWAPOrderDetails,
    executor: &Executor,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    clearing_house.assert_package_version();
    account.assert_order_ticket_exists(twap_order_ticket_id);
    let ticket: TWAPOrderTicket<T> = account.remove_order_ticket(twap_order_ticket_id);
    let executor_address = executor.executor_sender();
    ticket.assert_valid_ticket_executor(executor);
    ticket.assert_valid_ticket_clearing_house(object::id(clearing_house));
    assert_order_details_are_valid(new_details, &ticket.encrypted_details);
    assert!(ticket.is_complete(new_details.size), twap_order_not_completed!());

    let deallocated_collateral;
    if (!clearing_house.is_market_paused()) {
        deallocated_collateral = clearing_house.deallocate_collateral_internal(
            account,
            base_oracle,
            collateral_oracle,
            option::none(),
            clock,
        );
    } else {
        deallocated_collateral = 0;
    };
    events::e38<T>(
        ticket.id.to_inner(),
        ticket.account_id,
        executor_address,
        deallocated_collateral,
    );

    let TWAPOrderTicket {
        id,
        clearing_house_id: _,
        executors: _,
        execution_domain: _,
        gas,
        gas_execution_budget: _,
        account_id,
        encrypted_details: _,
        processed_amount: _,
        scheduled_amount: _,
        last_attempt_timestamp_ms: _,
        retry_anchor_timestamp_ms: _,
        last_execution_timestamp_ms: _,
        paid_execution_gas: _,
    } = ticket;
    events::e40<T>(id.to_inner(), account_id, executor_address);
    id.delete();
    coin::from_balance(gas, ctx)
}

public fun unfilled_scheduled_amount<T>(ticket: &TWAPOrderTicket<T>): u64 {
    ticket.scheduled_amount - ticket.processed_amount
}

public fun has_attempts<T>(ticket: &TWAPOrderTicket<T>): bool {
    ticket.last_attempt_timestamp_ms != 0
}

public fun is_first_execution<T>(ticket: &TWAPOrderTicket<T>): bool {
    !ticket.has_attempts()
}

public fun is_complete<T>(ticket: &TWAPOrderTicket<T>, order_size: u64): bool {
    ticket.processed_amount >= order_size
}

/// Whether the order is still within its retry window, measured from the last attempt that
/// started a new chunk (or filled something).
fun is_not_spoiled<T>(
    ticket: &TWAPOrderTicket<T>,
    new_details: &TWAPOrderDetails,
    timestamp_ms: u64
): bool {
    if (!ticket.has_attempts()) {
        return true
    };
    timestamp_ms - ticket.retry_anchor_timestamp_ms
        < new_details.time_for_retry_ms
            + new_details.execution_gap_ms
            + new_details.execution_time_uncertainty_ms
}

/// Runs one TWAP chunk as an immediate-or-cancel limit order capped by the maximum slippage
/// around the mark price, then records the attempt and pays the executor its share of the gas
/// budget.
public fun execute<T>(
    account: &mut Account<T>,
    clearing_house: ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    twap_order_ticket_id: ID,
    new_details: &TWAPOrderDetails,
    amount: u64,
    clock: &Clock,
    executor: &Executor,
    ctx: &mut TxContext
): (SessionSummary, Coin<HANEUL>, ClearingHouse<T>) {
    clearing_house.assert_package_version();
    clearing_house.assert_market_is_not_paused();
    assert!(ctx.gas_price() == ctx.reference_gas_price(), invalid_twap_order_gas_price!());

    account.assert_order_ticket_exists(twap_order_ticket_id);
    let mut ticket: TWAPOrderTicket<T> = account.remove_order_ticket(twap_order_ticket_id);
    ticket.assert_valid_ticket_executor(executor);
    ticket.assert_valid_ticket_clearing_house(object::id(&clearing_house));
    let lot_size = clearing_house.market_params().lot_size();
    let now = clock.timestamp_ms();
    ticket.assert_twap_order_can_be_executed(new_details, amount, now, lot_size);
    let account_id = ticket.account_id;

    // The blocks below correspond to macros of the original source: their leading bindings are
    // the macro parameters, kept so that the compiled code matches the published bytecode.

    // Amount newly scheduled by this run, and the order size (which also retries the scheduled
    // but unfilled amount of earlier runs).
    let (newly_scheduled_amount, execution_amount) = {
        let (ticket, details, lot_size) = (&ticket, new_details, lot_size);
        let chunk_amount = target_chunk_amount(details, lot_size);
        let unfilled_amount = ticket.unfilled_scheduled_amount();
        let unscheduled_amount = details.size - ticket.scheduled_amount;
        let mut amount = amount;
        let tail_merge_threshold =
            (chunk_amount as u128) * (details.small_tail_merge_threshold_bps as u128);
        let tail = unscheduled_amount % chunk_amount;
        // With one chunk left plus a small tail, the tail is merged into this last chunk.
        let merge_tail = unscheduled_amount / chunk_amount == 1
            && tail > 0
            && (tail as u128) * 10000 < tail_merge_threshold;
        if (merge_tail) {
            amount = unscheduled_amount;
        } else {
            amount = amount.min(unscheduled_amount);
        };
        let max_chunk_amount = {
            let details = details;
            let max_execution_bps = details.max_one_execution_amount_bps.min(10000);
            let max_amount =
                (((details.size as u128) * (max_execution_bps as u128) / 10000) as u64);
            max_amount - max_amount % lot_size
        };
        let max_execution_amount = if (merge_tail) {
            max_chunk_amount.max(amount)
        } else {
            max_chunk_amount
        };
        let retry_amount;
        if (unfilled_amount > 0 && amount < max_execution_amount) {
            retry_amount = unfilled_amount.min(max_execution_amount - amount);
        } else {
            retry_amount = 0;
        };
        let execution_amount = amount + retry_amount;
        assert!(
            execution_amount <= max_execution_amount,
            twap_order_amount_uncertainty_violated!(),
        );
        (amount, execution_amount)
    };

    let mut session = clearing_house.start_session_(
        account.account_id(),
        base_oracle,
        collateral_oracle,
        false,
        new_details.integrator_info,
        clock,
    );
    // Worst accepted price: the mark price moved against the order by the maximum slippage,
    // rounded to the tick size towards the mark price.
    let limit_price = {
        let (session, details) = (&session, new_details);
        let max_slippage = ifixed::from_u64fraction(details.max_slippage_bps, 10000);
        let is_bid = details.side == false;
        let tick_size = session.clearing_house().market_params().tick_size();
        let one = 1_000_000_000_000_000_000;
        let slippage_factor;
        if (is_bid) {
            slippage_factor = ifixed::add(one, max_slippage);
        } else {
            slippage_factor = ifixed::sub(one, max_slippage);
        };
        let price = ifixed::to_balance(
            ifixed::mul(session.mark_price_in_session(), slippage_factor),
            1_000_000_000,
        );
        let tick_remainder = price % tick_size;
        let limit_price;
        if (tick_remainder == 0) {
            limit_price = price;
        } else if (is_bid) {
            limit_price = price - tick_remainder;
        } else {
            limit_price = price + tick_size - tick_remainder;
        };
        limit_price
    };

    // Order type 3 is immediate-or-cancel.
    let session_ref = &mut session;
    let side = new_details.side;
    let size = execution_amount;
    let price = limit_price;
    let _ = session_ref.place_limit_order(
        side,
        size,
        price,
        3,
        option::none(),
        new_details.reduce_only,
        option::none(),
    );
    let summary = session.summary();
    let has_fills = summary.base_filled_bid() != 0 || summary.base_filled_ask() != 0;
    let (clearing_house, summary) = session.end_session_(
        account,
        !new_details.reduce_only && has_fills,
        false,
        true,
    );

    {
        let (ticket, details) = (&mut ticket, new_details);
        let filled_amount;
        if (details.side == false) {
            filled_amount = ifixed::to_balance(summary.base_filled_bid(), 1_000_000_000);
        } else {
            filled_amount = ifixed::to_balance(summary.base_filled_ask(), 1_000_000_000);
        };
        ticket.scheduled_amount = ticket.scheduled_amount + newly_scheduled_amount;
        if (ticket.last_attempt_timestamp_ms == 0) {
            ticket.retry_anchor_timestamp_ms = now
        };
        ticket.last_attempt_timestamp_ms = now;
        if (filled_amount != 0) {
            ticket.retry_anchor_timestamp_ms = now;
            ticket.last_execution_timestamp_ms = now;
            ticket.processed_amount = ticket.processed_amount + filled_amount
        };
        events::e37<T>(
            ticket.id.to_inner(),
            account_id,
            execution_amount,
            filled_amount,
            ticket.unfilled_scheduled_amount(),
            ticket.processed_amount,
            ticket.scheduled_amount,
            ticket.last_attempt_timestamp_ms,
            ticket.retry_anchor_timestamp_ms,
            ticket.last_execution_timestamp_ms,
        );
    };

    // The executor is paid the share of the gas budget matching the processed fraction of the
    // order, minus what earlier runs already paid.
    let gas_payment = {
        let ticket = &mut ticket;
        let processed_amount = ticket.processed_amount.min(new_details.size);
        let earned_gas = (
            (ticket.gas_execution_budget as u128) * (processed_amount as u128)
                / (new_details.size as u128)
        ) as u64;
        let payment = earned_gas - ticket.paid_execution_gas;
        ticket.paid_execution_gas = earned_gas;
        coin::from_balance(
            if (payment == 0) balance::zero() else ticket.gas.split(payment),
            ctx,
        )
    };
    let _ = account.add_order_ticket(ticket);
    (summary, gas_payment, clearing_house)
}

public fun set_details<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(twap_order_ticket_id);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    let ticket: &mut TWAPOrderTicket<T> = account.borrow_mut_order_ticket(twap_order_ticket_id);
    assert!(!ticket.has_attempts(), twap_order_cannot_edit_active_order!());
    ticket.encrypted_details = encrypted_details;
    events::e41<T>(ticket.id.to_inner(), ticket.account_id, encrypted_details)
}

public fun set_executors<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    executors: vector<address>,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    account.assert_order_ticket_exists(twap_order_ticket_id);
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    let ticket: &mut TWAPOrderTicket<T> = account.borrow_mut_order_ticket(twap_order_ticket_id);
    assert!(!ticket.has_attempts(), twap_order_cannot_edit_active_order!());
    ticket.executors = executors;
    events::e42<T>(ticket.id.to_inner(), ticket.account_id, executors)
}

/// The ticket only stores `blake2b256(bcs(details))`; executors reveal the details on each call.
fun assert_order_details_are_valid(
    new_details: &TWAPOrderDetails,
    encrypted_details: &vector<u8>,
) {
    assert!(
        hash::blake2b256(&bcs::to_bytes(new_details)) == *encrypted_details,
        invalid_order_details!(),
    )
}

public(package) fun assert_amount_within_uncertainty(
    new_details: &TWAPOrderDetails,
    desired_amount: u64,
    lot_size: u64,
) {
    let target_amount = target_chunk_amount(new_details, lot_size);
    let max_deviation =
        (target_amount as u128) * (new_details.amount_uncertainty_bps as u128) / 10000;
    assert!(
        (desired_amount.diff(target_amount) as u128) <= max_deviation,
        twap_order_amount_uncertainty_violated!(),
    )
}

fun assert_lot_compatible(
    new_details: &TWAPOrderDetails,
    desired_amount: u64,
    lot_size: u64,
) {
    assert!(
        new_details.size % lot_size == 0
            && new_details.size / lot_size >= new_details.chunks_amount
            && desired_amount % lot_size == 0,
        twap_order_invalid_lot_size!(),
    )
}

fun assert_valid_ticket_clearing_house<T>(
    ticket: &TWAPOrderTicket<T>,
    clearing_house_id: ID,
) {
    assert!(ticket.clearing_house_id == clearing_house_id, twap_order_invalid_clearing_house!())
}

fun assert_valid_ticket_executor<T>(
    ticket: &TWAPOrderTicket<T>,
    executor: &Executor
) {
    let executors = &ticket.executors;
    let executor_address = executor.executor_sender();
    assert!(executors.contains(&executor_address), twap_order_invalid_executor!());
    assert!(ticket.execution_domain == executor.executor_domain(), twap_order_invalid_executor!())
}

fun assert_execution_gap_within_uncertainty(
    new_details: &TWAPOrderDetails,
    actual_execution_gap_ms: u64,
) {
    if (actual_execution_gap_ms >= new_details.execution_gap_ms) {
        return
    };
    assert!(
        new_details.execution_gap_ms - actual_execution_gap_ms
            <= new_details.execution_time_uncertainty_ms,
        twap_order_execution_gap_violated!(),
    )
}

fun assert_twap_order_can_be_executed<T>(
    ticket: &TWAPOrderTicket<T>,
    new_details: &TWAPOrderDetails,
    amount: u64,
    timestamp_ms: u64,
    lot_size: u64,
) {
    assert_order_details_are_valid(new_details, &ticket.encrypted_details);
    assert_lot_compatible(new_details, amount, lot_size);
    assert!(ticket.processed_amount < new_details.size, twap_order_fully_executed!());
    // Only the first run is bound by `first_run_expire_timestamp`.
    if (!ticket.is_first_execution()) {
        // Not the first run.
    } else if (new_details.first_run_expire_timestamp.is_none()) {
        // No first-run deadline.
    } else {
        assert!(
            timestamp_ms < *new_details.first_run_expire_timestamp.borrow(),
            twap_order_first_run_expired!(),
        )
    };
    let _ = ticket;
    let expire_timestamp = new_details.expire_timestamp;
    let is_expired = expire_timestamp.is_some() && timestamp_ms > *expire_timestamp.borrow();
    assert!(!is_expired, twap_order_ticket_expired!());
    assert_amount_within_uncertainty(new_details, amount, lot_size);
    // Later runs must respect the execution gap and the retry window.
    let active = ticket;
    if (!active.has_attempts()) {
        // First run.
    } else {
        let execution_gap_ms = timestamp_ms - active.last_attempt_timestamp_ms;
        assert_execution_gap_within_uncertainty(new_details, execution_gap_ms);
        assert!(
            active.is_not_spoiled(new_details, timestamp_ms),
            twap_order_executed_after_retry_time!(),
        )
    }
}
