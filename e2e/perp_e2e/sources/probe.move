// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Read-only snapshots emitted as events, so the E2E driver can read engine state from a
/// dev-inspect call.
module perp_e2e::probe;

use haneul::clock::Clock;
use haneul::event;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::Account;
use perpetuals::clearing_house::ClearingHouse;

public struct PositionSnapshot has copy, drop {
    account_id: u64,
    exists: bool,
    collateral: u256,
    base: u256,
    quote: u256,
    pending_asks: u256,
    pending_bids: u256,
    pending_orders: u64,
    /// Funding accrued since the last settlement, not yet in `collateral` (USD, negative when owed).
    unsettled_funding: u256,
}

public struct MarketSnapshot has copy, drop {
    vault_collateral: u64,
    insurance_fund: u64,
    open_interest: u256,
    fees_accrued: u256,
    cum_funding_long: u256,
    cum_funding_short: u256,
    best_ask: Option<u64>,
    best_bid: Option<u64>,
    paused: u8,
}

public struct MarkSnapshot has copy, drop { mark_price: u256 }

public struct AccountSnapshot has copy, drop { account_id: u64, collateral: u64 }

public fun position<T>(ch: &ClearingHouse<T>, account_id: u64) {
    if (!ch.exists_position(account_id)) {
        event::emit(PositionSnapshot {
            account_id,
            exists: false,
            collateral: 0,
            base: 0,
            quote: 0,
            pending_asks: 0,
            pending_bids: 0,
            pending_orders: 0,
            unsettled_funding: 0,
        });
        return
    };
    let position = ch.position(account_id);
    let (cum_funding_long, cum_funding_short) = ch.market_state().cum_funding_rates();
    let (base, quote) = position.base_and_quote_amounts();
    let (pending_asks, pending_bids) = position.pending_base_amounts_by_side();
    event::emit(PositionSnapshot {
        account_id,
        exists: true,
        collateral: position.collateral(),
        base,
        quote,
        pending_asks,
        pending_bids,
        pending_orders: position.pending_order_count(),
        unsettled_funding: position.calculate_position_funding_internal(
            cum_funding_long,
            cum_funding_short,
        ),
    })
}

public fun market<T>(ch: &ClearingHouse<T>) {
    let (vault_collateral, insurance_fund) = ch.collateral_and_insurance_fund_balances();
    let state = ch.market_state();
    let (cum_funding_long, cum_funding_short) = state.cum_funding_rates();
    event::emit(MarketSnapshot {
        vault_collateral,
        insurance_fund,
        open_interest: state.open_interest(),
        fees_accrued: state.fees_accrued(),
        cum_funding_long,
        cum_funding_short,
        best_ask: ch.best_price_u64(true),
        best_bid: ch.best_price_u64(false),
        paused: ch.market_pause_mode(),
    })
}

public fun mark<T>(ch: &ClearingHouse<T>, base_oracle: &PriceFeedStorage, clock: &Clock) {
    event::emit(MarkSnapshot { mark_price: ch.mark_price(base_oracle, clock) })
}

public fun account<T>(account: &Account<T>) {
    event::emit(AccountSnapshot {
        account_id: account.account_id(),
        collateral: account.collateral_balance(),
    })
}

public struct VaultSnapshot has copy, drop { lp_supply: u64 }

public struct UserLpSnapshot has copy, drop { lp: u64, start_timestamp_ms: u64 }

public fun vault<L, C>(vault: &market_making_vault::vault::Vault<L, C>) {
    event::emit(VaultSnapshot { lp_supply: vault.lp_supply_value() })
}

public fun user_lp<L>(coin: &market_making_vault::vault::UserLpCoin<L>) {
    let (lp, start_timestamp_ms) = market_making_vault::vault::user_lp_coin_info(coin);
    event::emit(UserLpSnapshot { lp, start_timestamp_ms })
}
