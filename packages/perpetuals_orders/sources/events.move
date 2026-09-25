// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals_orders::events;

use haneul::event;

// === Types ===

public struct CreatedStopOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: u64,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
}

public struct ExecutedStopOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executor: address,
}

public struct DeletedStopOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executor: address,
}

public struct EditedStopOrderTicketDetails<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    encrypted_details: vector<u8>,
}

public struct EditedStopOrderTicketExecutors<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executors: vector<address>,
}

public struct CreatedTWAPOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    ch_id: ID,
    account_id: u64,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: u64,
    encrypted_details: vector<u8>,
}

public struct ProcessedTWAPOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    execution_amount: u64,
    filled_amount: u64,
    remainder: u64,
    processed_amount: u64,
    scheduled_amount: u64,
    last_attempt_timestamp_ms: u64,
    retry_anchor_timestamp_ms: u64,
    last_execution_timestamp_ms: u64,
}

public struct FinalizedTWAPOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executor: address,
    deallocated_collateral: u64,
}

public struct CanceledTWAPOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    sender: address,
    deallocated_collateral: u64,
    partial_fill: bool,
}

public struct DeletedTWAPOrderTicket<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executor: address,
}

public struct EditedTWAPOrderTicketDetails<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    encrypted_details: vector<u8>,
}

public struct EditedTWAPOrderTicketExecutors<phantom T> has copy, drop {
    ticket_id: ID,
    account_id: u64,
    executors: vector<address>,
}

// === Functions ===

/// Emits `CreatedStopOrderTicket`.
public(package) fun created_stop_order_ticket<T>(
    ticket_id: ID,
    account_id: u64,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: u64,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
) {
    event::emit(CreatedStopOrderTicket<T> {
        ticket_id,
        account_id,
        executors,
        execution_domain,
        gas,
        stop_order_type,
        encrypted_details,
    })
}

/// Emits `ExecutedStopOrderTicket`.
public(package) fun executed_stop_order_ticket<T>(ticket_id: ID, account_id: u64, executor: address) {
    event::emit(ExecutedStopOrderTicket<T> { ticket_id, account_id, executor })
}

/// Emits `DeletedStopOrderTicket`.
public(package) fun deleted_stop_order_ticket<T>(ticket_id: ID, account_id: u64, executor: address) {
    event::emit(DeletedStopOrderTicket<T> { ticket_id, account_id, executor })
}

/// Emits `EditedStopOrderTicketDetails`.
public(package) fun edited_stop_order_ticket_details<T>(ticket_id: ID, account_id: u64, encrypted_details: vector<u8>) {
    event::emit(EditedStopOrderTicketDetails<T> { ticket_id, account_id, encrypted_details })
}

/// Emits `EditedStopOrderTicketExecutors`.
public(package) fun edited_stop_order_ticket_executors<T>(ticket_id: ID, account_id: u64, executors: vector<address>) {
    event::emit(EditedStopOrderTicketExecutors<T> { ticket_id, account_id, executors })
}

/// Emits `CreatedTWAPOrderTicket`.
public(package) fun created_twap_order_ticket<T>(
    ticket_id: ID,
    ch_id: ID,
    account_id: u64,
    executors: vector<address>,
    execution_domain: Option<address>,
    gas: u64,
    encrypted_details: vector<u8>,
) {
    event::emit(CreatedTWAPOrderTicket<T> {
        ticket_id,
        ch_id,
        account_id,
        executors,
        execution_domain,
        gas,
        encrypted_details,
    })
}

/// Emits `ProcessedTWAPOrderTicket`.
public(package) fun processed_twap_order_ticket<T>(
    ticket_id: ID,
    account_id: u64,
    execution_amount: u64,
    filled_amount: u64,
    remainder: u64,
    processed_amount: u64,
    scheduled_amount: u64,
    last_attempt_timestamp_ms: u64,
    retry_anchor_timestamp_ms: u64,
    last_execution_timestamp_ms: u64,
) {
    event::emit(ProcessedTWAPOrderTicket<T> {
        ticket_id,
        account_id,
        execution_amount,
        filled_amount,
        remainder,
        processed_amount,
        scheduled_amount,
        last_attempt_timestamp_ms,
        retry_anchor_timestamp_ms,
        last_execution_timestamp_ms,
    })
}

/// Emits `FinalizedTWAPOrderTicket`.
public(package) fun finalized_twap_order_ticket<T>(
    ticket_id: ID,
    account_id: u64,
    executor: address,
    deallocated_collateral: u64,
) {
    event::emit(FinalizedTWAPOrderTicket<T> {
        ticket_id,
        account_id,
        executor,
        deallocated_collateral,
    })
}

/// Emits `CanceledTWAPOrderTicket`.
public(package) fun canceled_twap_order_ticket<T>(
    ticket_id: ID,
    account_id: u64,
    sender: address,
    deallocated_collateral: u64,
    partial_fill: bool,
) {
    event::emit(CanceledTWAPOrderTicket<T> {
        ticket_id,
        account_id,
        sender,
        deallocated_collateral,
        partial_fill,
    })
}

/// Emits `DeletedTWAPOrderTicket`.
public(package) fun deleted_twap_order_ticket<T>(ticket_id: ID, account_id: u64, executor: address) {
    event::emit(DeletedTWAPOrderTicket<T> { ticket_id, account_id, executor })
}

/// Emits `EditedTWAPOrderTicketDetails`.
public(package) fun edited_twap_order_ticket_details<T>(ticket_id: ID, account_id: u64, encrypted_details: vector<u8>) {
    event::emit(EditedTWAPOrderTicketDetails<T> { ticket_id, account_id, encrypted_details })
}

/// Emits `EditedTWAPOrderTicketExecutors`.
public(package) fun edited_twap_order_ticket_executors<T>(ticket_id: ID, account_id: u64, executors: vector<address>) {
    event::emit(EditedTWAPOrderTicketExecutors<T> { ticket_id, account_id, executors })
}
