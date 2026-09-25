// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::interface;

use authority_cap::authority::{ADMIN, ASSISTANT, AuthorityCap};
use haneul::clock::Clock;
use haneul::coin::{Coin, CoinMetadata, TreasuryCap};
use haneul::coin_registry::{CoinRegistry, Currency};
use haneul::haneul::HANEUL;
use market_making_vault::authority::{
    FREEZE_GUARDIAN,
    MAINTENANCE,
    PACKAGE,
    PAUSE_GUARDIAN,
    TREASURY,
    VAULT,
};
use market_making_vault::config::Config;
use market_making_vault::metadata::VaultMetadata;
use market_making_vault::perpetuals_api;
use market_making_vault::vault::{Self, DepositSession, UserLpCoin, Vault, WithdrawSession};
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::{Account, IntegratorInfo};
use perpetuals::clearing_house::{ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals::twap_orders::TWAPOrderDetails;
use std::ascii::String;

// === Functions ===

public fun join<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    config: &mut Config,
    other_user_lp_coin: UserLpCoin<L>,
) {
    config.assert_package_version();
    user_lp_coin.join_user_lp_coin(config, other_user_lp_coin)
}

public fun split<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    config: &mut Config,
    amount: u64,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    config.assert_package_version();
    user_lp_coin.split_user_lp_coin(config, amount, ctx)
}

public fun create_vault<L, C>(
    perps_registry: &mut Registry,
    config: &mut Config,
    lp_treasury_cap: TreasuryCap<L>,
    coin_registry: &mut CoinRegistry,
    lp_coin_metadata: &CoinMetadata<L>,
    collateral_metadata: &CoinMetadata<C>,
    collateral_oracle: &PriceFeedStorage,
    lock_period: u64,
    owner_fee_rate: u256,
    force_withdraw_delay: u64,
    owner_locked_liquidity: Coin<C>,
    name: String,
    description: String,
    curator_name: Option<String>,
    curator_url: Option<String>,
    curator_logo_url: Option<String>,
    extra_field_keys: Option<vector<String>>,
    extra_field_values: Option<vector<String>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_package_version();
    vault::new(
        perps_registry,
        config,
        lp_treasury_cap,
        coin_registry,
        lp_coin_metadata,
        collateral_metadata,
        collateral_oracle,
        lock_period,
        owner_fee_rate,
        force_withdraw_delay,
        owner_locked_liquidity,
        name,
        description,
        curator_name,
        curator_url,
        curator_logo_url,
        extra_field_keys,
        extra_field_values,
        clock,
        ctx,
    )
}

public fun create_vault_with_currency<L, C>(
    perps_registry: &mut Registry,
    config: &mut Config,
    lp_treasury_cap: TreasuryCap<L>,
    lp_currency: &Currency<L>,
    collateral_currency: &Currency<C>,
    collateral_oracle: &PriceFeedStorage,
    lock_period: u64,
    owner_fee_rate: u256,
    force_withdraw_delay: u64,
    owner_locked_liquidity: Coin<C>,
    name: String,
    description: String,
    curator_name: Option<String>,
    curator_url: Option<String>,
    curator_logo_url: Option<String>,
    extra_field_keys: Option<vector<String>>,
    extra_field_values: Option<vector<String>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_package_version();
    vault::new_with_currency(
        perps_registry,
        config,
        lp_treasury_cap,
        lp_currency,
        collateral_currency,
        collateral_oracle,
        lock_period,
        owner_fee_rate,
        force_withdraw_delay,
        owner_locked_liquidity,
        name,
        description,
        curator_name,
        curator_url,
        curator_logo_url,
        extra_field_keys,
        extra_field_values,
        clock,
        ctx,
    )
}

public fun create_vault_with_collateral_currency<L, C>(
    perps_registry: &mut Registry,
    config: &mut Config,
    lp_treasury_cap: TreasuryCap<L>,
    coin_registry: &mut CoinRegistry,
    lp_coin_metadata: &CoinMetadata<L>,
    collateral_currency: &Currency<C>,
    collateral_oracle: &PriceFeedStorage,
    lock_period: u64,
    owner_fee_rate: u256,
    force_withdraw_delay: u64,
    owner_locked_liquidity: Coin<C>,
    name: String,
    description: String,
    curator_name: Option<String>,
    curator_url: Option<String>,
    curator_logo_url: Option<String>,
    extra_field_keys: Option<vector<String>>,
    extra_field_values: Option<vector<String>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_package_version();
    vault::new_with_collateral_currency(
        perps_registry,
        config,
        lp_treasury_cap,
        coin_registry,
        lp_coin_metadata,
        collateral_currency,
        collateral_oracle,
        lock_period,
        owner_fee_rate,
        force_withdraw_delay,
        owner_locked_liquidity,
        name,
        description,
        curator_name,
        curator_url,
        curator_logo_url,
        extra_field_keys,
        extra_field_values,
        clock,
        ctx,
    )
}

public fun add_yield<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    perps_registry: &Registry,
    coin_in: Coin<C>,
) {
    vault.assert_package_version();
    vault.add_yield(account, perps_registry, coin_in)
}

public fun start_deposit_session<L, C>(
    vault: Vault<L, C>,
    config: &Config,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    coin: Coin<C>,
    clock: &Clock,
    ctx: &TxContext,
): DepositSession<L, C> {
    config.assert_package_version();
    vault.start_deposit_session(config, account, collateral_oracle, coin, clock, ctx)
}

public fun process_clearing_house_for_deposit<L, C>(
    deposit_session: &mut DepositSession<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    deposit_session.assert_deposit_session_package_version();
    deposit_session.process_clearing_house_for_deposit(clearing_house, base_oracle, clock)
}

public fun end_deposit_session<L, C>(
    deposit_session: DepositSession<L, C>,
    config: &mut Config,
    min_expected_lp_coin_out: u64,
    perps_registry: &Registry,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    deposit_session.assert_deposit_session_package_version();
    deposit_session.end_deposit_session(config, min_expected_lp_coin_out, perps_registry, ctx)
}

public fun create_withdraw_request<L, C>(
    vault: &mut Vault<L, C>,
    config: &mut Config,
    user_lp_coin: UserLpCoin<L>,
    lp_coin_amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault.assert_package_version();
    vault.create_withdraw_request(
        config,
        user_lp_coin,
        lp_coin_amount,
        min_expected_balance_out,
        clock,
        ctx,
    )
}

public fun remove_withdraw_request<L, C>(
    vault: &mut Vault<L, C>,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    vault.assert_package_version();
    vault.remove_withdraw_request(ctx)
}

public fun set_new_withdraw_request_slippage<L, C>(
    vault: &mut Vault<L, C>,
    min_expected_balance_out: u64,
    ctx: &mut TxContext,
) {
    vault.assert_package_version();
    vault.set_new_withdraw_request_slippage(min_expected_balance_out, ctx)
}

public fun pause_vault_for_force_withdraw<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    clock: &Clock,
    ctx: &TxContext,
) {
    config.assert_package_version();
    vault.pause_vault_for_force_withdraw(config, clock, ctx.sender())
}

public fun resume_vault_for_force_withdraw<L, C>(
    vault: &mut Vault<L, C>,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.resume_vault_for_force_withdraw(clock)
}

public fun start_force_withdraw_session<L, C>(
    vault: Vault<L, C>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    ctx: &TxContext,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.start_force_withdraw_session(account, collateral_oracle, ctx.sender(), clock)
}

public fun process_clearing_house_for_force_withdraw<L, C>(
    withdraw_session: &mut WithdrawSession<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    size_to_close: u64,
    order_ids: &vector<u128>,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
) {
    withdraw_session.assert_withdraw_session_package_version();
    withdraw_session.process_clearing_house_for_force_withdraw(
        clearing_house,
        base_oracle,
        collateral_oracle,
        size_to_close,
        order_ids,
        integrator_info,
        clock,
        ctx,
    )
}

public fun end_withdraw_session_and_transfer_to_recipient<L, C>(
    withdraw_session: WithdrawSession<L, C>,
    config: &mut Config,
    perps_registry: &Registry,
    ctx: &mut TxContext,
) {
    withdraw_session.assert_withdraw_session_package_version();
    withdraw_session.end_withdraw_session_and_transfer_to_recipient(config, perps_registry, ctx)
}

public fun end_withdraw_session<L, C>(
    withdraw_session: WithdrawSession<L, C>,
    config: &mut Config,
    perps_registry: &Registry,
    ctx: &mut TxContext,
): Coin<C> {
    withdraw_session.assert_withdraw_session_package_version();
    withdraw_session.end_withdraw_session(config, perps_registry, ctx)
}

entry fun upgrade_config_version<ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    config.assert_authority_cap_is_valid(cap);
    config.upgrade_version()
}

entry fun upgrade_vault_version<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    config.assert_authority_cap_is_valid(cap);
    vault.upgrade_vault_version()
}

public fun set_deposit_session_sender<L, C, ADMIN_OR_ASSISTANT>(
    deposit_session: &mut DepositSession<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    sender: address,
) {
    deposit_session.assert_deposit_session_package_version();
    config.assert_authority_cap_is_valid(cap);
    deposit_session.assert_deposit_session_package_version();
    deposit_session.set_deposit_session_sender(sender)
}

entry fun set_min_pause_vault_for_force_withdraw_frequency_ms<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    min_pause_vault_for_force_withdraw_frequency_ms: u64,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_min_pause_vault_for_force_withdraw_frequency_ms(
        min_pause_vault_for_force_withdraw_frequency_ms,
    )
}

entry fun set_min_force_withdraw_position_usd<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    min_force_withdraw_position_usd: u256,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_min_force_withdraw_position_usd(min_force_withdraw_position_usd)
}

entry fun set_max_force_withdraw_mr_tolerance<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    max_force_withdraw_mr_tolerance: u256,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_max_force_withdraw_mr_tolerance(config, max_force_withdraw_mr_tolerance)
}

public fun admin_set_max_markets_in_vault<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    max_markets_in_vault: u64,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.admin_set_max_markets_in_vault(max_markets_in_vault)
}

public fun set_max_pending_orders_per_position<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    max_pending_orders_per_position: u64,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_max_pending_orders_per_position(config, max_pending_orders_per_position)
}

public fun clip_lock_period<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_lock_period(config)
}

public fun clip_force_withdraw_delay<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_force_withdraw_delay(config)
}

public fun clip_owner_fee_rate<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_owner_fee_rate(config)
}

public fun clip_min_owner_lock_usd<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_min_owner_lock_usd(config)
}

public fun clip_max_markets_in_vault<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_max_markets_in_vault(config)
}

public fun clip_max_pending_orders_per_position<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.clip_max_pending_orders_per_position(config)
}

entry fun set_collateral_pfs_info<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    perps_registry: &Registry,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_collateral_pfs_info(perps_registry)
}

entry fun set_collateral_pfs_tolerance<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    collateral_pfs_tolerance: u64,
) {
    vault.assert_package_version();
    config.assert_authority_cap_is_valid(cap);
    vault.set_collateral_pfs_tolerance(collateral_pfs_tolerance)
}

public fun admin_pause_vault<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, PAUSE_GUARDIAN>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_is_active_package_pause_guardian_cap(cap);
    vault.admin_pause_vault()
}

public fun admin_unpause_vault<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, PAUSE_GUARDIAN>,
    config: &Config,
) {
    vault.assert_package_version();
    config.assert_is_active_package_pause_guardian_cap(cap);
    vault.admin_unpause_vault()
}

public fun freeze_vault<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
    config: &Config,
) {
    vault.freeze_vault(config, cap)
}

public fun unfreeze_vault<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
) {
    vault.unfreeze_vault(cap)
}

public fun admin_pause_vault_for_force_withdraw<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, MAINTENANCE>,
    config: &Config,
    clock: &Clock,
    withdraw_request_address: address,
) {
    vault.assert_package_version();
    config.assert_is_active_package_maintenance_cap(cap);
    vault.admin_pause_vault_for_force_withdraw(config, clock, withdraw_request_address)
}

public fun admin_start_force_withdraw_session_for_address<L, C>(
    vault: Vault<L, C>,
    cap: &AuthorityCap<PACKAGE, MAINTENANCE>,
    config: &Config,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    address: address,
    clock: &Clock,
    _ctx: &TxContext, // Kept for future use if needed.
): WithdrawSession<L, C> {
    vault.assert_package_version();
    config.assert_is_active_package_maintenance_cap(cap);
    vault.start_force_withdraw_session(account, collateral_oracle, address, clock)
}

public fun withdraw_fees<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, TREASURY>,
    amount_to_withdraw: u64,
    ctx: &mut TxContext,
): Coin<C> {
    vault.assert_package_version();
    vault.assert_vault_treasury_cap_is_valid(cap);
    vault.withdraw_fees(amount_to_withdraw, ctx)
}

public fun new_vault_assistant_cap<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN>,
    config: &Config,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<L>, ASSISTANT> {
    config.assert_package_version();
    vault.new_vault_assistant_cap(cap, config, ctx)
}

public fun new_vault_treasury_cap<L, C>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<L>, TREASURY> {
    vault.assert_package_version();
    vault.new_vault_treasury_cap(cap, ctx)
}

public fun deauthorize_vault_authority_cap<L, C, Role>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN>,
    cap_id: ID,
) {
    if (!(vault.is_frozen())) {
        vault.assert_package_version()
    };
    vault.deauthorize_vault_authority_cap<L, C, Role>(cap, cap_id)
}

public fun start_owner_locked_withdraw_session<L, C>(
    vault: Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.start_owner_locked_withdraw_session(
        account,
        collateral_oracle,
        amount,
        min_expected_balance_out,
        clock,
        ctx,
    )
}

public fun start_owner_withdraw_session<L, C, ADMIN_OR_ASSISTANT>(
    vault: Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &mut Config,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    user_lp_coin: UserLpCoin<L>,
    amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.start_owner_withdraw_session(
        config,
        account,
        collateral_oracle,
        user_lp_coin,
        amount,
        min_expected_balance_out,
        clock,
        ctx,
    )
}

public fun start_owner_process_withdraw_request<L, C, ADMIN_OR_ASSISTANT>(
    vault: Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    target_request_address: address,
    clock: &Clock,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.start_owner_process_withdraw_request(
        account,
        collateral_oracle,
        target_request_address,
        clock,
    )
}

public fun process_clearing_house_for_withdraw<L, C, ADMIN_OR_ASSISTANT>(
    withdraw_session: &mut WithdrawSession<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    withdraw_session.assert_withdraw_session_package_version();
    withdraw_session.assert_withdraw_session_cap_has_authority(cap);
    withdraw_session.process_clearing_house_for_withdraw(clearing_house, base_oracle, clock)
}

public fun set_owner_fee_rate<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    owner_fee_rate: u256,
) {
    config.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.set_owner_fee_rate(config, owner_fee_rate)
}

public fun set_lock_period<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    lock_period: u64,
) {
    config.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.set_lock_period(config, lock_period)
}

public fun set_max_total_deposited_collateral<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    max_total_deposited_collateral: u64,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.set_max_total_deposited_collateral(max_total_deposited_collateral)
}

public fun set_force_withdraw_delay<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    force_withdraw_delay: u64,
) {
    config.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    vault.set_force_withdraw_delay(config, force_withdraw_delay)
}

public fun allocate_collateral_to_position<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    amount: u64,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::allocate_collateral_to_position(vault, account, clearing_house, amount, clock)
}

public fun deallocate_collateral_from_position<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount_to_withdraw: Option<u64>,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::deallocate_collateral_from_position(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        amount_to_withdraw,
        clock,
    )
}

public fun close_position_at_settlement_prices<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
) {
    perpetuals_api::close_position_at_settlement_prices(vault, account, clearing_house, order_ids)
}

public fun reconcile_clearing_house<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &Account<C>,
    clearing_house: &ClearingHouse<C>,
) {
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::reconcile_clearing_house(vault, account, clearing_house)
}

public fun remove_empty_clearing_house<L, C>(
    vault: &mut Vault<L, C>,
    account: &Account<C>,
    clearing_house: &ClearingHouse<C>,
) {
    perpetuals_api::remove_empty_clearing_house(vault, account, clearing_house)
}

public fun place_market_order<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    side: bool,
    size: u64,
    reduce_only: bool,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::place_market_order(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        side,
        size,
        reduce_only,
        integrator_info,
        clock,
        ctx,
    )
}

public fun place_limit_order<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    side: bool,
    size: u64,
    price: u64,
    order_type: u64,
    client_order_id: Option<u64>,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<C>, Option<u128>) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::place_limit_order(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        side,
        size,
        price,
        order_type,
        client_order_id,
        reduce_only,
        expiration_timestamp_ms,
        integrator_info,
        clock,
        ctx,
    )
}

public fun cancel_orders<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::cancel_orders(vault, account, clearing_house, order_ids, clock)
}

public fun try_cancel_orders<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
    clock: &Clock,
): vector<bool> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::try_cancel_orders(vault, account, clearing_house, order_ids, clock)
}

public fun liquidate<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    liqee_account_id: u64,
    cancel_order_ids: &vector<u128>,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::liquidate(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        liqee_account_id,
        cancel_order_ids,
        integrator_info,
        clock,
        ctx,
    )
}

public fun start_perpetuals_session<L, C, ADMIN_OR_ASSISTANT>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
): SessionHotPotato<C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::start_perpetuals_session(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        integrator_info,
        clock,
        ctx,
    )
}

public fun end_perpetuals_session<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    hot_potato: SessionHotPotato<C>,
    allocate_missing_margin: bool,
    deallocate_free_collateral: bool,
): ClearingHouse<C> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::end_perpetuals_session(
        vault,
        account,
        hot_potato,
        allocate_missing_margin,
        deallocate_free_collateral,
    )
}

public fun set_position_initial_margin_ratio<L, C, ADMIN_OR_ASSISTANT>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    initial_margin_ratio: u256,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::set_position_initial_margin_ratio(
        vault,
        account,
        clearing_house,
        initial_margin_ratio,
    )
}

public fun create_market_position<L, C, ADMIN_OR_ASSISTANT>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::create_market_position(vault, account, clearing_house)
}

public fun create_stop_order_ticket<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    executors: vector<address>,
    gas: Coin<HANEUL>,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext,
): ID {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::create_stop_order_ticket(
        vault,
        account,
        registry,
        executors,
        gas,
        stop_order_type,
        encrypted_details,
        ctx,
    )
}

public fun edit_stop_order_ticket_details<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::edit_stop_order_ticket_details(
        vault,
        account,
        registry,
        stop_order_ticket_id,
        encrypted_details,
    )
}

public fun edit_stop_order_ticket_executors<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    executors: vector<address>,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::edit_stop_order_ticket_executors(
        vault,
        account,
        registry,
        stop_order_ticket_id,
        executors,
    )
}

public fun admin_delete_stop_order_ticket<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::user_delete_stop_order_ticket(
        vault,
        account,
        registry,
        stop_order_ticket_id,
        ctx,
    )
}

public fun create_twap_order_ticket<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: &ClearingHouse<C>,
    executors: vector<address>,
    gas: Coin<HANEUL>,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext,
): ID {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::create_twap_order_ticket(
        vault,
        account,
        clearing_house,
        executors,
        gas,
        encrypted_details,
        ctx,
    )
}

public fun edit_twap_order_ticket_details<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::edit_twap_order_ticket_details(
        vault,
        account,
        registry,
        twap_order_ticket_id,
        encrypted_details,
    )
}

public fun edit_twap_order_ticket_executors<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    executors: vector<address>,
) {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::edit_twap_order_ticket_executors(
        vault,
        account,
        registry,
        twap_order_ticket_id,
        executors,
    )
}

public fun admin_cancel_twap_order<L, C, ADMIN_OR_ASSISTANT>(
    vault: &mut Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    twap_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(cap);
    perpetuals_api::user_cancel_twap_order(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        twap_order_ticket_id,
        ctx,
    )
}

public fun place_stop_order_sltp<L, C>(
    vault: &mut Vault<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    stop_order_ticket_id: ID,
    account: &mut Account<C>,
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
    clock: &Clock,
    ctx: &mut TxContext,
): (SessionSummary, Coin<HANEUL>, ClearingHouse<C>) {
    vault.assert_package_version();
    perpetuals_api::place_stop_order_sltp(
        vault,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        stop_order_ticket_id,
        account,
        expire_timestamp,
        is_limit_order,
        trigger_price_type,
        stop_loss_price,
        take_profit_price,
        position_is_ask,
        size,
        price,
        order_type,
        salt,
        integrator_info,
        ctx,
    )
}

public fun place_stop_order_standalone<L, C>(
    vault: &mut Vault<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    stop_order_ticket_id: ID,
    account: &mut Account<C>,
    expire_timestamp: Option<u64>,
    is_limit_order: bool,
    trigger_price_type: u8,
    stop_trigger_price: u256,
    ge_stop_trigger_price: bool,
    side: bool,
    size: u64,
    price: u64,
    order_type: u64,
    reduce_only: bool,
    salt: vector<u8>,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &mut TxContext,
): (SessionSummary, Coin<HANEUL>, ClearingHouse<C>) {
    vault.assert_package_version();
    perpetuals_api::place_stop_order_standalone(
        vault,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        stop_order_ticket_id,
        account,
        expire_timestamp,
        is_limit_order,
        trigger_price_type,
        stop_trigger_price,
        ge_stop_trigger_price,
        side,
        size,
        price,
        order_type,
        reduce_only,
        salt,
        integrator_info,
        ctx,
    )
}

public fun delete_stop_order_ticket<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    perpetuals_api::delete_stop_order_ticket(vault, account, registry, stop_order_ticket_id, ctx)
}

public fun execute_twap_order<L, C>(
    vault: &mut Vault<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    twap_order_ticket_id: ID,
    account: &mut Account<C>,
    new_details: &TWAPOrderDetails,
    amount: u64,
    ctx: &mut TxContext,
): (SessionSummary, Coin<HANEUL>, ClearingHouse<C>) {
    vault.assert_package_version();
    perpetuals_api::execute_twap_order(
        vault,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        twap_order_ticket_id,
        account,
        new_details,
        amount,
        ctx,
    )
}

public fun finalize_twap_order<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    twap_order_ticket_id: ID,
    new_details: &TWAPOrderDetails,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    perpetuals_api::finalize_twap_order(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        twap_order_ticket_id,
        new_details,
        ctx,
    )
}

public fun cancel_twap_order<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    twap_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    perpetuals_api::cancel_twap_order(
        vault,
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        twap_order_ticket_id,
        ctx,
    )
}

public fun create_package_assistant_cap(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    config.assert_package_version();
    config.create_package_assistant_cap_(cap, ctx)
}

public fun create_package_pause_guardian_cap(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, PAUSE_GUARDIAN> {
    config.assert_package_version();
    config.create_package_pause_guardian_cap_(cap, ctx)
}

public fun create_package_maintenance_cap(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, MAINTENANCE> {
    config.assert_package_version();
    config.create_package_maintenance_cap_(cap, ctx)
}

public fun create_package_freeze_guardian_cap(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    config.assert_package_version();
    config.create_package_freeze_guardian_cap_(cap, ctx)
}

public fun deauthorize_package_authority_cap<Role>(
    config: &mut Config,
    cap: &AuthorityCap<PACKAGE, ADMIN>,
    cap_id: ID,
) {
    config.assert_package_version();
    config.deauthorize_package_authority_cap_<Role>(cap, cap_id)
}

public fun set_name<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    name: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_name(name)
}

public fun set_description<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    description: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_description(description)
}

public fun set_curator_name<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    curator_name: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_curator_name(curator_name)
}

public fun set_curator_url<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    curator_url: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_curator_url(curator_url)
}

public fun set_curator_logo_url<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    curator_logo_url: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_curator_logo_url(curator_logo_url)
}

public fun set_extra_field<L, C, ADMIN_OR_ASSISTANT>(
    metadata: &mut VaultMetadata<L>,
    cap: &AuthorityCap<VAULT<L>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    vault: &Vault<L, C>,
    key: String,
    value: String,
) {
    config.assert_package_version();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(cap);
    metadata.set_extra_field(key, value)
}
