// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::events;

use haneul::event;
use std::string::String;
use std::type_name::TypeName;

// === Types ===

public struct UpgradedVersion has copy, drop { id: ID, version: u64 }

public struct CreatedAccount<phantom T> has copy, drop {
    account_obj_id: ID,
    user: address,
    account_id: u64,
}

public struct DepositedCollateral<phantom T> has copy, drop { account_id: u64, collateral: u64 }

public struct AllocatedCollateral has copy, drop { ch_id: ID, account_id: u64, collateral: u64 }

public struct WithdrewCollateral<phantom T> has copy, drop { account_id: u64, collateral: u64 }

public struct RegisteredCollateralInfo<phantom T> has copy, drop {
    storage_id: u32,
    source_id: u16,
    scaling_factor: u256,
}

public struct DeallocatedCollateral has copy, drop { ch_id: ID, account_id: u64, collateral: u64 }

public struct CreatedClearingHouse has copy, drop {
    ch_id: ID,
    collateral: String,
    coin_decimals: u64,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
    base_storage_id: u32,
    base_source_id: u16,
    collateral_storage_id: u32,
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
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
    priority_taker_fee: Option<u256>,
}

public struct ClosedMarket has copy, drop { ch_id: ID }

public struct UpdatedSettlementPrices has copy, drop {
    ch_id: ID,
    base_settlement_price: u256,
    collateral_settlement_price: u256,
    settlement_enabled: bool,
}

public struct UpdatedIntegratorAddress has copy, drop {
    integrator_id: u32,
    previous_integrator_address: address,
    new_integrator_address: address,
}

public struct UpdatedPremiumTwap has copy, drop {
    ch_id: ID,
    actual_book_price: u256,
    clipped_book_price: u256,
    index_price: u256,
    premium_twap: u256,
    premium_twap_last_upd_ms: u64,
}

public struct UpdatedSpreadTwap has copy, drop {
    ch_id: ID,
    actual_book_price: u256,
    clipped_book_price: u256,
    index_price: u256,
    spread_twap: u256,
    spread_twap_last_upd_ms: u64,
}

public struct UpdatedFunding has copy, drop {
    ch_id: ID,
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
    funding_last_upd_ms: u64,
}

public struct SettledFunding has copy, drop {
    ch_id: ID,
    account_id: u64,
    collateral_change_usd: u256,
    collateral_after: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
}

public struct SetPositionInitialMarginRatio has copy, drop {
    ch_id: ID,
    account_id: u64,
    initial_margin_ratio: u256,
}

public struct FilledMakerOrders has copy, drop {
    events: vector<FilledMakerOrder>,
    book_price: Option<u64>,
}

public struct FilledMakerOrder has copy, drop {
    ch_id: ID,
    maker_account_id: u64,
    taker_account_id: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    filled_size: u64,
    remaining_size: u64,
    canceled_size: u64,
    cancelation_reason: Option<u8>,
    pnl: u256,
    maker_fees: u256,
    mark_price: u256,
    integrator_id: Option<u32>,
    integrator_fee_paid_usd: u256,
}

public struct FilledTakerOrder has copy, drop {
    ch_id: ID,
    taker_account_id: u64,
    taker_pnl: u256,
    taker_fees: u256,
    integrator_id: Option<u32>,
    integrator_fee_paid_usd: u256,
    base_asset_delta_ask: u256,
    quote_asset_delta_ask: u256,
    base_asset_delta_bid: u256,
    quote_asset_delta_bid: u256,
    mark_price: u256,
}

public struct ClosedPositionAtSettlementPrices has copy, drop {
    ch_id: ID,
    account_id: u64,
    pnl: u256,
    base_asset_amount: u256,
    quote_asset_amount: u256,
    deallocated_collateral: u64,
    bad_debt: u256,
}

public struct PostedOrder has copy, drop {
    ch_id: ID,
    account_id: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    order_size: u64,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
    integrator_id: Option<u32>,
    integrator_fee_rate: u32,
    mark_price: u256,
    book_price: Option<u64>,
}

public struct CanceledOrder has copy, drop {
    ch_id: ID,
    account_id: u64,
    size: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    cancelation_reason: u8,
    book_price: Option<u64>,
}

public struct LiquidatedPosition has copy, drop {
    ch_id: ID,
    liqee_account_id: u64,
    liqor_account_id: u64,
    is_liqee_long: bool,
    base_liquidated: u256,
    quote_liquidated: u256,
    liqee_pnl: u256,
    liquidation_fees: u256,
    insurance_fund_fees: u256,
    bad_debt: u256,
    mark_price: u256,
}

public struct PerformedLiquidation has copy, drop {
    ch_id: ID,
    liqee_account_id: u64,
    liqor_account_id: u64,
    is_liqee_long: bool,
    base_liquidated: u256,
    quote_liquidated: u256,
    liqor_pnl: u256,
    liqor_fees: u256,
    mark_price: u256,
}

public struct PerformedADL has copy, drop {
    ch_id: ID,
    bad_debt_account_id: u64,
    size_reduced: u64,
    collateral_transferred: u256,
    adl_price: u64,
    counterparty_account_id: u64,
    bad_debt_is_long: bool,
}

public struct SocializedBadDebt has copy, drop {
    ch_id: ID,
    bad_debt_usd: u256,
    socialized_fundings: u256,
    added_to_long: bool,
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
}

public struct CreatedPosition has copy, drop {
    ch_id: ID,
    account_id: u64,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
}

public struct UpdatedMarginRatios has copy, drop {
    ch_id: ID,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
}

public struct SetFeeParams has copy, drop {
    ch_id: ID,
    maker_fee: u256,
    taker_fee: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    priority_taker_fee: Option<u256>,
}

public struct SetFeeMultiplier has copy, drop {
    ch_id: ID,
    account_id: u64,
    taker_multiplier: u256,
    maker_multiplier: u256,
    expires_ms: u64,
}

public struct SetTwapParams has copy, drop {
    ch_id: ID,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
}

public struct SetCoreParams has copy, drop {
    ch_id: ID,
    lot_size: u64,
    tick_size: u64,
    collateral_haircut: u256,
}

public struct SetBaseOracleParams has copy, drop {
    ch_id: ID,
    storage_id: u32,
    source_id: u16,
    pfs_tolerance: u64,
}

public struct SetCollateralOracleParams has copy, drop {
    ch_id: ID,
    storage_id: u32,
    source_id: u16,
    pfs_tolerance: u64,
}

public struct SetRiskLimitParams has copy, drop {
    ch_id: ID,
    min_order_usd_value: u256,
    max_pending_orders: u64,
    max_open_interest: u256,
    max_open_interest_threshold: u256,
    max_open_interest_position_percent: u256,
    max_book_index_spread: u256,
    max_index_twap_divergence: u256,
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
    max_funding_rate: u256,
}

public struct DonatedToInsuranceFund has copy, drop {
    sender: address,
    ch_id: ID,
    amount: u64,
    new_balance: u64,
}

public struct WithdrewFees has copy, drop {
    sender: address,
    ch_id: ID,
    amount: u64,
    vault_balance_after: u64,
}

public struct WithdrewInsuranceFund has copy, drop {
    sender: address,
    ch_id: ID,
    amount: u64,
    insurance_fund_balance_after: u64,
}

public struct UpdatedOpenInterestAndFeesAccrued has copy, drop {
    ch_id: ID,
    open_interest: u256,
    fees_accrued: u256,
}

public struct RegisteredVendor has copy, drop { vendor_key: TypeName, vendor_admin_cap_id: ID }

public struct Froze has copy, drop { id: ID, resume_version: u64, guardian_cap_id: ID }

public struct Unfroze has copy, drop { id: ID, version: u64 }

// === Functions ===

/// Emits `CreatedAccount`.
public(package) fun created_account<T>(account_obj_id: ID, user: address, account_id: u64) {
    event::emit(CreatedAccount<T> { account_obj_id, user, account_id })
}

/// Emits `DepositedCollateral`.
public(package) fun deposited_collateral<T>(account_id: u64, collateral: u64) {
    event::emit(DepositedCollateral<T> { account_id, collateral })
}

/// Emits `AllocatedCollateral`.
public(package) fun allocated_collateral(ch_id: ID, account_id: u64, collateral: u64) {
    event::emit(AllocatedCollateral { ch_id, account_id, collateral })
}

/// Emits `CreatedClearingHouse`.
public(package) fun created_clearing_house(
    ch_id: ID,
    collateral: String,
    coin_decimals: u64,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
    base_storage_id: u32,
    base_source_id: u16,
    collateral_storage_id: u32,
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
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
    priority_taker_fee: Option<u256>,
) {
    event::emit(CreatedClearingHouse {
        ch_id,
        collateral,
        coin_decimals,
        margin_ratio_initial,
        margin_ratio_maintenance,
        base_storage_id,
        base_source_id,
        collateral_storage_id,
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
        max_bad_debt,
        max_socialize_losses_mr_decrease,
        priority_taker_fee,
    })
}

/// Emits `UpgradedVersion`.
public(package) fun upgraded_version(id: ID, version: u64) {
    event::emit(UpgradedVersion { id, version })
}

/// Emits `RegisteredVendor`.
public(package) fun registered_vendor(vendor_key: TypeName, vendor_admin_cap_id: ID) {
    event::emit(RegisteredVendor { vendor_key, vendor_admin_cap_id })
}

/// Emits `Froze`.
public(package) fun froze(id: ID, resume_version: u64, guardian_cap_id: ID) {
    event::emit(Froze { id, resume_version, guardian_cap_id })
}

/// Emits `Unfroze`.
public(package) fun unfroze(id: ID, version: u64) {
    event::emit(Unfroze { id, version })
}

/// Emits `ClosedMarket`.
public(package) fun closed_market(ch_id: ID) {
    event::emit(ClosedMarket { ch_id })
}

/// Emits `UpdatedSettlementPrices`.
public(package) fun updated_settlement_prices(
    ch_id: ID,
    base_settlement_price: u256,
    collateral_settlement_price: u256,
    settlement_enabled: bool,
) {
    event::emit(UpdatedSettlementPrices {
        ch_id,
        base_settlement_price,
        collateral_settlement_price,
        settlement_enabled,
    })
}

/// Emits `UpdatedIntegratorAddress`.
public(package) fun updated_integrator_address(
    integrator_id: u32,
    previous_integrator_address: address,
    new_integrator_address: address,
) {
    event::emit(UpdatedIntegratorAddress {
        integrator_id,
        previous_integrator_address,
        new_integrator_address,
    })
}

/// Emits `UpdatedPremiumTwap`.
public(package) fun updated_premium_twap(
    ch_id: ID,
    actual_book_price: u256,
    clipped_book_price: u256,
    index_price: u256,
    premium_twap: u256,
    premium_twap_last_upd_ms: u64,
) {
    event::emit(UpdatedPremiumTwap {
        ch_id,
        actual_book_price,
        clipped_book_price,
        index_price,
        premium_twap,
        premium_twap_last_upd_ms,
    })
}

/// Emits `UpdatedSpreadTwap`.
public(package) fun updated_spread_twap(
    ch_id: ID,
    actual_book_price: u256,
    clipped_book_price: u256,
    index_price: u256,
    spread_twap: u256,
    spread_twap_last_upd_ms: u64,
) {
    event::emit(UpdatedSpreadTwap {
        ch_id,
        actual_book_price,
        clipped_book_price,
        index_price,
        spread_twap,
        spread_twap_last_upd_ms,
    })
}

/// Emits `UpdatedFunding`.
public(package) fun updated_funding(
    ch_id: ID,
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
    funding_last_upd_ms: u64,
) {
    event::emit(UpdatedFunding {
        ch_id,
        cum_funding_rate_long,
        cum_funding_rate_short,
        funding_last_upd_ms,
    })
}

/// Emits `SettledFunding`.
public(package) fun settled_funding(
    ch_id: ID,
    account_id: u64,
    collateral_change_usd: u256,
    collateral_after: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
) {
    event::emit(SettledFunding {
        ch_id,
        account_id,
        collateral_change_usd,
        collateral_after,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
    })
}

/// Emits `SetPositionInitialMarginRatio`.
public(package) fun set_position_initial_margin_ratio(ch_id: ID, account_id: u64, initial_margin_ratio: u256) {
    event::emit(SetPositionInitialMarginRatio { ch_id, account_id, initial_margin_ratio })
}

/// Emits `PostedOrder`.
public(package) fun posted_order(
    ch_id: ID,
    account_id: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    order_size: u64,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
    integrator_id: Option<u32>,
    integrator_fee_rate: u32,
    mark_price: u256,
    book_price: Option<u64>,
) {
    event::emit(PostedOrder {
        ch_id,
        account_id,
        order_id,
        client_order_id,
        order_size,
        reduce_only,
        expiration_timestamp_ms,
        integrator_id,
        integrator_fee_rate,
        mark_price,
        book_price,
    })
}

/// Emits `FilledMakerOrders`.
public(package) fun filled_maker_orders(events: vector<FilledMakerOrder>, book_price: Option<u64>) {
    event::emit(FilledMakerOrders { events, book_price })
}

/// Builds a `FilledMakerOrder` entry for a `FilledMakerOrders` event.
public(package) fun filled_maker_order(
    ch_id: ID,
    maker_account_id: u64,
    taker_account_id: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    filled_size: u64,
    remaining_size: u64,
    canceled_size: u64,
    cancelation_reason: Option<u8>,
    pnl: u256,
    maker_fees: u256,
    mark_price: u256,
    integrator_id: Option<u32>,
    integrator_fee_paid_usd: u256,
): FilledMakerOrder {
    FilledMakerOrder {
        ch_id,
        maker_account_id,
        taker_account_id,
        order_id,
        client_order_id,
        filled_size,
        remaining_size,
        canceled_size,
        cancelation_reason,
        pnl,
        maker_fees,
        mark_price,
        integrator_id,
        integrator_fee_paid_usd,
    }
}

/// Emits `FilledTakerOrder`.
public(package) fun filled_taker_order(
    ch_id: ID,
    taker_account_id: u64,
    taker_pnl: u256,
    taker_fees: u256,
    integrator_id: Option<u32>,
    integrator_fee_paid_usd: u256,
    base_asset_delta_ask: u256,
    quote_asset_delta_ask: u256,
    base_asset_delta_bid: u256,
    quote_asset_delta_bid: u256,
    mark_price: u256,
) {
    event::emit(FilledTakerOrder {
        ch_id,
        taker_account_id,
        taker_pnl,
        taker_fees,
        integrator_id,
        integrator_fee_paid_usd,
        base_asset_delta_ask,
        quote_asset_delta_ask,
        base_asset_delta_bid,
        quote_asset_delta_bid,
        mark_price,
    })
}

/// Emits `ClosedPositionAtSettlementPrices`.
public(package) fun closed_position_at_settlement_prices(
    ch_id: ID,
    account_id: u64,
    pnl: u256,
    base_asset_amount: u256,
    quote_asset_amount: u256,
    deallocated_collateral: u64,
    bad_debt: u256,
) {
    event::emit(ClosedPositionAtSettlementPrices {
        ch_id,
        account_id,
        pnl,
        base_asset_amount,
        quote_asset_amount,
        deallocated_collateral,
        bad_debt,
    })
}

/// Emits `CanceledOrder`.
public(package) fun canceled_order(
    ch_id: ID,
    account_id: u64,
    order_id: u128,
    client_order_id: Option<u64>,
    size: u64,
    cancelation_reason: u8,
    book_price: Option<u64>,
) {
    event::emit(CanceledOrder {
        ch_id,
        account_id,
        order_id,
        client_order_id,
        size,
        cancelation_reason,
        book_price,
    })
}

/// Emits `LiquidatedPosition`.
public(package) fun liquidated_position(
    ch_id: ID,
    liqee_account_id: u64,
    liqor_account_id: u64,
    is_liqee_long: bool,
    base_liquidated: u256,
    quote_liquidated: u256,
    liqee_pnl: u256,
    liquidation_fees: u256,
    insurance_fund_fees: u256,
    bad_debt: u256,
    mark_price: u256,
) {
    event::emit(LiquidatedPosition {
        ch_id,
        liqee_account_id,
        liqor_account_id,
        is_liqee_long,
        base_liquidated,
        quote_liquidated,
        liqee_pnl,
        liquidation_fees,
        insurance_fund_fees,
        bad_debt,
        mark_price,
    })
}

/// Emits `PerformedLiquidation`.
public(package) fun performed_liquidation(
    ch_id: ID,
    liqee_account_id: u64,
    liqor_account_id: u64,
    is_liqee_long: bool,
    base_liquidated: u256,
    quote_liquidated: u256,
    liqor_pnl: u256,
    liqor_fees: u256,
    mark_price: u256,
) {
    event::emit(PerformedLiquidation {
        ch_id,
        liqee_account_id,
        liqor_account_id,
        is_liqee_long,
        base_liquidated,
        quote_liquidated,
        liqor_pnl,
        liqor_fees,
        mark_price,
    })
}

/// Emits `PerformedADL`.
public(package) fun performed_adl(
    ch_id: ID,
    bad_debt_account_id: u64,
    size_reduced: u64,
    collateral_transferred: u256,
    adl_price: u64,
    counterparty_account_id: u64,
    bad_debt_is_long: bool,
) {
    event::emit(PerformedADL {
        ch_id,
        bad_debt_account_id,
        size_reduced,
        collateral_transferred,
        adl_price,
        counterparty_account_id,
        bad_debt_is_long,
    })
}

/// Emits `SocializedBadDebt`.
public(package) fun socialized_bad_debt(
    ch_id: ID,
    bad_debt_usd: u256,
    socialized_fundings: u256,
    added_to_long: bool,
    cum_funding_rate_long: u256,
    cum_funding_rate_short: u256,
) {
    event::emit(SocializedBadDebt {
        ch_id,
        bad_debt_usd,
        socialized_fundings,
        added_to_long,
        cum_funding_rate_long,
        cum_funding_rate_short,
    })
}

/// Emits `WithdrewCollateral`.
public(package) fun withdrew_collateral<T>(account_id: u64, collateral: u64) {
    event::emit(WithdrewCollateral<T> { account_id, collateral })
}

/// Emits `RegisteredCollateralInfo`.
public(package) fun registered_collateral_info<T>(storage_id: u32, source_id: u16, scaling_factor: u256) {
    event::emit(RegisteredCollateralInfo<T> { storage_id, source_id, scaling_factor })
}

/// Emits `DeallocatedCollateral`.
public(package) fun deallocated_collateral(ch_id: ID, account_id: u64, collateral: u64) {
    event::emit(DeallocatedCollateral { ch_id, account_id, collateral })
}

/// Emits `CreatedPosition`.
public(package) fun created_position(
    ch_id: ID,
    account_id: u64,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
) {
    event::emit(CreatedPosition {
        ch_id,
        account_id,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
    })
}

/// Emits `UpdatedMarginRatios`.
public(package) fun updated_margin_ratios(ch_id: ID, margin_ratio_initial: u256, margin_ratio_maintenance: u256) {
    event::emit(UpdatedMarginRatios { ch_id, margin_ratio_initial, margin_ratio_maintenance })
}

/// Emits `SetFeeMultiplier`.
public(package) fun set_fee_multiplier(
    ch_id: ID,
    account_id: u64,
    taker_multiplier: u256,
    maker_multiplier: u256,
    expires_ms: u64,
) {
    event::emit(SetFeeMultiplier { ch_id, account_id, taker_multiplier, maker_multiplier, expires_ms })
}

/// Emits `SetFeeParams`.
public(package) fun set_fee_params(
    ch_id: ID,
    maker_fee: u256,
    taker_fee: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    priority_taker_fee: Option<u256>,
) {
    event::emit(SetFeeParams {
        ch_id,
        maker_fee,
        taker_fee,
        liquidation_fee,
        insurance_fund_fee,
        priority_taker_fee,
    })
}

/// Emits `SetTwapParams`.
public(package) fun set_twap_params(
    ch_id: ID,
    funding_frequency_ms: u64,
    funding_period_ms: u64,
    premium_twap_frequency_ms: u64,
    premium_twap_period_ms: u64,
    spread_twap_frequency_ms: u64,
    spread_twap_period_ms: u64,
) {
    event::emit(SetTwapParams {
        ch_id,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
        spread_twap_frequency_ms,
        spread_twap_period_ms,
    })
}

/// Emits `SetCoreParams`.
public(package) fun set_core_params(ch_id: ID, lot_size: u64, tick_size: u64, collateral_haircut: u256) {
    event::emit(SetCoreParams { ch_id, lot_size, tick_size, collateral_haircut })
}

/// Emits `SetBaseOracleParams`.
public(package) fun set_base_oracle_params(ch_id: ID, storage_id: u32, source_id: u16, pfs_tolerance: u64) {
    event::emit(SetBaseOracleParams { ch_id, storage_id, source_id, pfs_tolerance })
}

/// Emits `SetCollateralOracleParams`.
public(package) fun set_collateral_oracle_params(ch_id: ID, storage_id: u32, source_id: u16, pfs_tolerance: u64) {
    event::emit(SetCollateralOracleParams { ch_id, storage_id, source_id, pfs_tolerance })
}

/// Emits `SetRiskLimitParams`.
public(package) fun set_risk_limit_params(
    ch_id: ID,
    min_order_usd_value: u256,
    max_pending_orders: u64,
    max_open_interest: u256,
    max_open_interest_threshold: u256,
    max_open_interest_position_percent: u256,
    max_book_index_spread: u256,
    max_index_twap_divergence: u256,
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
    max_funding_rate: u256,
) {
    event::emit(SetRiskLimitParams {
        ch_id,
        min_order_usd_value,
        max_pending_orders,
        max_open_interest,
        max_open_interest_threshold,
        max_open_interest_position_percent,
        max_book_index_spread,
        max_index_twap_divergence,
        max_bad_debt,
        max_socialize_losses_mr_decrease,
        max_funding_rate,
    })
}

/// Emits `DonatedToInsuranceFund`.
public(package) fun donated_to_insurance_fund(sender: address, ch_id: ID, amount: u64, new_balance: u64) {
    event::emit(DonatedToInsuranceFund { sender, ch_id, amount, new_balance })
}

/// Emits `WithdrewFees`.
public(package) fun withdrew_fees(sender: address, ch_id: ID, amount: u64, vault_balance_after: u64) {
    event::emit(WithdrewFees { sender, ch_id, amount, vault_balance_after })
}

/// Emits `WithdrewInsuranceFund`.
public(package) fun withdrew_insurance_fund(
    sender: address,
    ch_id: ID,
    amount: u64,
    insurance_fund_balance_after: u64,
) {
    event::emit(WithdrewInsuranceFund { sender, ch_id, amount, insurance_fund_balance_after })
}

/// Emits `UpdatedOpenInterestAndFeesAccrued`.
public(package) fun updated_open_interest_and_fees_accrued(ch_id: ID, open_interest: u256, fees_accrued: u256) {
    event::emit(UpdatedOpenInterestAndFeesAccrued { ch_id, open_interest, fees_accrued })
}

/// Returns the maker fees and integrator fees recorded in a `FilledMakerOrder`.
public(package) fun maker_and_integrator_fees(event: &FilledMakerOrder): (u256, u256) {
    (event.maker_fees, event.integrator_fee_paid_usd)
}
