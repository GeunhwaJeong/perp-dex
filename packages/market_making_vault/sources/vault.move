// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::vault;

use authority_cap::authority::{Self as cap_authority, ADMIN, ASSISTANT, AuthorityCap};
use haneul::balance::{Self, Balance, Supply};
use haneul::clock::Clock;
use haneul::coin::{Coin, CoinMetadata, TreasuryCap};
use haneul::coin_registry::{CoinRegistry, Currency};
use haneul::dynamic_field;
use haneul::dynamic_object_field;
use ifixed::ifixed;
use market_making_vault::authority::{Self, FREEZE_GUARDIAN, PACKAGE, TREASURY, VAULT};
use market_making_vault::config::{Self, Config};
use market_making_vault::errors;
use market_making_vault::events;
use market_making_vault::keys::{Self, WithdrawRequestKey};
use market_making_vault::metadata;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::{Self, Account, IntegratorInfo};
use perpetuals::authority::ACCOUNT;
use perpetuals::clearing_house::{Self, ClearingHouse, Executor};
use perpetuals::market;
use perpetuals::registry::Registry;
use std::ascii::String;
use std::type_name;
use std::u256;
use std::u64;

// === Errors and constants ===

#[error(code = 0)]
const EInvalidVaultAuthorityCap: vector<u8> = b"The provided AuthorityCap does not have permission to manage this Vault.";
#[error(code = 1)]
const EInvalidAccountAuthorityCap: vector<u8> = b"The provided Account is not authorized for this Vault.";
const B9_SCALING: u256 = 0_000_000_001_000_000_000;

// === Types ===

public struct VaultParams has store {
    lock_period: u64,
    owner_fee_rate: u256,
    force_withdraw_delay: u64,
    min_pause_vault_for_force_withdraw_frequency_ms: u64,
    collateral_storage_id: u32,
    collateral_source_id: u16,
    collateral_pfs_tolerance: u64,
    max_force_withdraw_mr_tolerance: u256,
    min_force_withdraw_position_usd: u256,
    min_owner_lock_usd: u256,
    scaling_factor: u256,
    max_markets_in_vault: u64,
    max_pending_orders_per_position: u64,
    max_total_deposited_collateral: u64,
}

public struct Vault<phantom L, phantom C> has key, store {
    id: UID,
    version: u64,
    lp_supply: Supply<L>,
    ch_ids: vector<ID>,
    paused: Option<u64>,
    last_paused_timestamp_ms: u64,
    vault_params: VaultParams,
}

public struct UserLpCoin<phantom L> has key, store {
    id: UID,
    lp_balance: Balance<L>,
    start_timestamp_ms: u64,
    provided_value_usd: u256,
}

public struct DepositSession<phantom L, phantom C> {
    vault: Vault<L, C>,
    account: Account<C>,
    sender: address,
    timestamp_ms: u64,
    collateral_price: u256,
    ch_ids: vector<ID>,
    vault_balance_value: u256,
    provided_balance: Balance<C>,
}

public struct WithdrawRequest<phantom L> has store {
    user_lp_coin: UserLpCoin<L>,
    request_timestamp_ms: u64,
    min_expected_balance_out: u64,
}

public struct WithdrawSession<phantom L, phantom C> {
    vault: Vault<L, C>,
    account: Account<C>,
    sender: address,
    collateral_price: u256,
    ch_ids: vector<ID>,
    user_lp_coin: UserLpCoin<L>,
    vault_balance_value: u256,
    accumulated_slippage: u256,
    accumulated_withdraw_dust: u256,
    can_force_process: bool,
    min_expected_balance_out: u64,
}

// === Private macros reconstructed from repeated inlined code (not stored on-chain) ===

/// Pauses `$vault` for the package's `force_withdraw_pause_ms` once the withdraw request of
/// `$withdraw_request_address` has waited out the vault's force-withdraw delay. An admin pause
/// is left in place. `$now` is expanded at each use.
macro fun pause_for_force_withdraw<$L, $C>(
    $vault: &mut Vault<$L, $C>,
    $config: &Config,
    $withdraw_request_address: address,
    $now: u64,
) {
    let vault = $vault;
    vault.assert_package_version();
    vault.assert_withdraw_request_exists($withdraw_request_address);
    assert!(
        dynamic_field::borrow<WithdrawRequestKey, WithdrawRequest<$L>>(
            &vault.id,
            keys::withdraw_request($withdraw_request_address),
        ).request_timestamp_ms + vault.vault_params.force_withdraw_delay <= $now,
        errors::force_withdraw_delay_not_passed(),
    );
    if (!vault.paused.is_some_and!(|paused_until| *paused_until == u64::max_value!())) {
        vault.paused = option::some($now + config::force_withdraw_pause_ms($config))
    }
}

/// Closes a withdraw session once every clearing house has been processed: burns the session's
/// LP coin, withdraws its share of the vault's value from the perpetuals account, takes the
/// owner fee on any profit and returns the withdrawn collateral. The vault and account are
/// shared again.
#[allow(lint(share_owned))]
macro fun settle_withdraw_session<$L, $C>(
    $withdraw_session: WithdrawSession<$L, $C>,
    $config: &mut Config,
    $perps_registry: &Registry,
    $ctx: &mut TxContext,
): Coin<$C> {
    let WithdrawSession {
        vault: mut vault,
        account: mut account,
        sender,
        collateral_price,
        ch_ids,
        user_lp_coin,
        vault_balance_value,
        accumulated_slippage,
        accumulated_withdraw_dust,
        can_force_process,
        min_expected_balance_out,
    } = $withdraw_session;
    vault.assert_vault_is_not_admin_paused();
    let user_lp_coin_id = user_lp_coin.id.to_inner();
    let UserLpCoin {
        id,
        lp_balance,
        start_timestamp_ms: _,
        provided_value_usd,
    } = user_lp_coin;
    assert!(ch_ids.is_empty(), errors::not_all_chs_processed());
    vault.assert_package_version();

    // The vault value (idle collateral plus the margin counted in every market) excludes the
    // slippage realised while closing positions for this withdrawal, so that the withdrawer alone
    // bears it: they get their LP share of that value plus the (usually negative) slippage,
    // minus the rounding dust left behind in clearing houses.
    let scaling_factor = vault.vault_params.scaling_factor;
    let vault_value = ifixed::add(
        ifixed::add(
            ifixed::mul(
                ifixed::from_balance(account.collateral_balance(), scaling_factor),
                collateral_price,
            ),
            vault_balance_value,
        ),
        ifixed::neg(accumulated_slippage),
    );
    let withdraw_value = ifixed::sub(
        ifixed::add(
            multiply_by_rational_ifixed(
                ifixed::from_balance(lp_balance.value(), B9_SCALING),
                vault_value,
                ifixed::from_balance(vault.lp_supply_value(), B9_SCALING),
            ),
            accumulated_slippage,
        ),
        accumulated_withdraw_dust,
    );
    assert!(!ifixed::is_neg(withdraw_value), errors::slippage_check());
    let withdraw_amount = ifixed::to_balance(
        ifixed::div(withdraw_value, collateral_price),
        scaling_factor,
    );
    let mut collateral_out = account.withdraw_collateral(
        vault.account_cap(),
        $perps_registry,
        withdraw_amount,
        $ctx,
    );
    let lp_coin_amount = lp_balance.value();
    vault.lp_supply.decrease_supply(lp_balance);

    // The owner's locked LP coin is marked by a maximal provided value and has no config record.
    let is_owner_locked = provided_value_usd == u256::max_value!();
    if (!is_owner_locked) {
        config::unregister_user_lp_coin($config, user_lp_coin_id)
    };
    id.delete();

    // The owner fee is a share of the profit over the value originally provided.
    if (
        !is_owner_locked && (
            ifixed::greater_than(vault.vault_params.owner_fee_rate, 0) &&
                ifixed::greater_than(withdraw_value, provided_value_usd)
        )
    ) {
        let fee_value = ifixed::mul(
            ifixed::sub(withdraw_value, provided_value_usd),
            vault.vault_params.owner_fee_rate,
        );
        let fee = collateral_out
            .balance_mut()
            .split(ifixed::to_balance(ifixed::div(fee_value, collateral_price), scaling_factor));
        vault.owner_fees_mut().join(fee);
    };

    let vault_id = vault.id();
    let amount_out = collateral_out.value();
    assert!(min_expected_balance_out <= amount_out, errors::slippage_check());
    transfer::public_share_object(account);
    if (can_force_process) {
        events::emit_user_force_withdraw(
            vault_id,
            sender,
            lp_coin_amount,
            amount_out,
            vault_balance_value,
        )
    } else if (is_owner_locked) {
        // The owner must keep some locked LP, worth at least `min_owner_lock_usd` afterwards.
        let remaining_locked_lp = vault.owner_locked_lp_balance().value();
        assert!(remaining_locked_lp != 0, errors::owner_locked_amount_too_low_after_withdraw());
        let remaining_vault_value = ifixed::sub(
            vault_value,
            ifixed::mul(ifixed::from_balance(amount_out, scaling_factor), collateral_price),
        );
        assert!(
            ifixed::greater_than_eq(
                multiply_by_rational_ifixed(
                    ifixed::from_balance(remaining_locked_lp, B9_SCALING),
                    remaining_vault_value,
                    ifixed::from_balance(vault.lp_supply_value(), B9_SCALING),
                ),
                vault.vault_params.min_owner_lock_usd,
            ),
            errors::owner_locked_amount_too_low_after_withdraw(),
        );
        events::emit_owner_locked_liquidity_withdraw(
            vault_id,
            sender,
            lp_coin_amount,
            amount_out,
            remaining_locked_lp,
        )
    } else {
        events::emit_owner_withdraw(
            vault_id,
            sender,
            lp_coin_amount,
            amount_out,
            vault_balance_value,
        )
    };
    transfer::public_share_object(vault);
    collateral_out
}

// === Functions ===

public(package) fun new<L, C>(
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
    new_impl(
        perps_registry,
        config,
        lp_treasury_cap,
        lp_coin_metadata.get_decimals(),
        collateral_metadata.get_decimals(),
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
    );
    if (!coin_registry.exists<L>()) {
        coin_registry.migrate_legacy_metadata(lp_coin_metadata, ctx)
    }
}

public(package) fun new_with_currency<L, C>(
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
    new_impl(
        perps_registry,
        config,
        lp_treasury_cap,
        lp_currency.decimals(),
        collateral_currency.decimals(),
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

public(package) fun new_with_collateral_currency<L, C>(
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
    new_impl(
        perps_registry,
        config,
        lp_treasury_cap,
        lp_coin_metadata.get_decimals(),
        collateral_currency.decimals(),
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
    );
    if (!coin_registry.exists<L>()) {
        coin_registry.migrate_legacy_metadata(lp_coin_metadata, ctx)
    }
}

#[allow(lint(self_transfer))]
fun new_impl<L, C>(
    perps_registry: &mut Registry,
    config: &mut Config,
    lp_treasury_cap: TreasuryCap<L>,
    lp_decimals: u8,
    collateral_decimals: u8,
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
    assert!(lp_treasury_cap.total_supply() == 0, errors::non_zero_total_supply());
    // LP coins are minted one unit per collateral unit, so both must use the same decimals.
    assert!(lp_decimals == collateral_decimals, errors::invalid_decimals());
    assert_vault_creation_parameters_are_valid(
        config,
        lock_period,
        owner_fee_rate,
        force_withdraw_delay,
    );

    let collateral_pfs_tolerance = config.collateral_pfs_tolerance();
    let (collateral_storage_id, collateral_source_id, scaling_factor) =
        perps_registry.collateral_info<C>();
    assert!(
        collateral_storage_id == collateral_oracle.storage_id(),
        errors::wrong_collateral_oracle(),
    );
    assert_minimum_owner_locked_liquidity_with_oracle(
        config,
        collateral_oracle,
        collateral_source_id,
        collateral_pfs_tolerance,
        clock,
        owner_locked_liquidity.value(),
        scaling_factor,
    );

    let vault_params = VaultParams {
        collateral_storage_id,
        collateral_source_id,
        collateral_pfs_tolerance,
        scaling_factor,
        lock_period,
        owner_fee_rate,
        force_withdraw_delay,
        min_owner_lock_usd: config.min_owner_lock_usd(),
        max_markets_in_vault: config.max_markets_in_vault(),
        max_pending_orders_per_position: config.max_pending_orders_per_position(),
        // 30 minutes.
        min_pause_vault_for_force_withdraw_frequency_ms: 1_800_000,
        // 0.005 and $5, as 18-decimal fixed-point numbers.
        max_force_withdraw_mr_tolerance: 5_000_000_000_000_000,
        min_force_withdraw_position_usd: 5_000_000_000_000_000_000,
        // No deposit cap until the owner sets one.
        max_total_deposited_collateral: u64::max_value!(),
    };
    let mut vault = Vault<L, C> {
        id: object::new(ctx),
        version: 1,
        lp_supply: lp_treasury_cap.treasury_into_supply(),
        ch_ids: vector[],
        paused: option::none(),
        last_paused_timestamp_ms: 0,
        vault_params,
    };
    let sender = ctx.sender();
    let vault_id = vault.id();
    let admin_cap = authority::create_vault_admin_cap<L>(&mut vault.id);
    let admin_cap_id = object::id(&admin_cap);
    let treasury_cap = authority::create_vault_treasury_cap<L>(&mut vault.id, ctx);
    let treasury_cap_id = object::id(&treasury_cap);

    // The vault trades through its own perpetuals account, seeded with the owner's liquidity.
    let (mut account, share_policy, account_cap) = account::create_account<C>(perps_registry, ctx);
    let account_id = account.account_id();
    let initial_liquidity = owner_locked_liquidity.value();
    account.deposit_collateral(&account_cap, perps_registry, owner_locked_liquidity);
    account.consume_policy_and_share_account(share_policy);

    dynamic_object_field::add(&mut vault.id, keys::account_cap_key(), account_cap);
    dynamic_field::add(&mut vault.id, keys::owner_fees_key(), balance::zero<C>());
    dynamic_field::add(&mut vault.id, keys::active_assistant_count_key(), 0u64);
    cap_authority::authorize_cap(&mut vault.id, &treasury_cap);

    // The owner's liquidity stays locked in the vault as LP minted one-to-one.
    let owner_locked_lp = vault.lp_supply.increase_supply(initial_liquidity);
    dynamic_field::add(&mut vault.id, keys::owner_user_lp_coin_key(), owner_locked_lp);

    let vault_metadata = metadata::new<L>(
        &mut vault.id,
        name,
        description,
        curator_name,
        curator_url,
        curator_logo_url,
        extra_field_keys,
        extra_field_values,
    );
    let vault_metadata_id = object::id(&vault_metadata);
    config.register_vault(vault_id, admin_cap_id, vault_metadata_id, clock.timestamp_ms());
    events::emit_created_vault_event(
        vault_id,
        vault_metadata_id,
        admin_cap_id,
        collateral_storage_id,
        type_name::with_defining_ids<L>().into_string().to_string(),
        type_name::with_defining_ids<C>().into_string().to_string(),
        lp_decimals,
        initial_liquidity,
        sender,
        account_id,
        lock_period,
    );
    events::emit_create_vault_treasury_cap(vault_id, treasury_cap_id);

    transfer::public_transfer(admin_cap, sender);
    transfer::public_transfer(treasury_cap, sender);
    transfer::share_object(vault);
    transfer::public_share_object(vault_metadata)
}

fun share_clearing_house<C>(clearing_house: ClearingHouse<C>) {
    clearing_house.share()
}

public(package) fun account_cap<L, C>(vault: &Vault<L, C>): &AuthorityCap<ACCOUNT, ADMIN> {
    dynamic_object_field::borrow(&vault.id, keys::account_cap_key())
}

public fun is_authority_cap_authorized<L, C, Role>(
    vault: &Vault<L, C>,
    cap_id: ID,
): bool {
    cap_authority::is_cap_authorized<VAULT<L>, Role>(&vault.id, cap_id)
}

public fun active_assistant_count<L, C>(
    vault: &Vault<L, C>,
): u64 {
    *dynamic_field::borrow(&vault.id, keys::active_assistant_count_key())
}

public(package) fun id<L, C>(vault: &Vault<L, C>): ID {
    vault.id.to_inner()
}

public(package) fun execution_domain<L, C>(vault: &Vault<L, C>): address {
    vault.id.to_address()
}

public(package) fun executor<L, C>(vault: &Vault<L, C>, ctx: &TxContext): Executor {
    clearing_house::domain_executor(&vault.id, ctx)
}

public(package) fun version<L, C>(vault: &Vault<L, C>): u64 {
    vault.version
}

public fun is_frozen<L, C>(
    vault: &Vault<L, C>,
): bool {
    dynamic_field::exists(&vault.id, keys::frozen_version_key())
}

public fun lp_supply_value<L, C>(
    vault: &Vault<L, C>,
): u64 {
    vault.lp_supply.supply_value()
}

public(package) fun lock_period<L, C>(vault: &Vault<L, C>): u64 {
    vault.vault_params.lock_period
}

public(package) fun force_withdraw_delay<L, C>(vault: &Vault<L, C>): u64 {
    vault.vault_params.force_withdraw_delay
}

public(package) fun ch_ids<L, C>(vault: &Vault<L, C>): vector<ID> {
    vault.ch_ids
}

public(package) fun ch_ids_mut<L, C>(vault: &mut Vault<L, C>): &mut vector<ID> {
    &mut vault.ch_ids
}

public(package) fun remove_ch_id<L, C>(vault: &mut Vault<L, C>, clearing_house_id: ID) {
    let idx = vault.ch_ids.find_index!(|id| *id == clearing_house_id);
    idx.do!(|i| { vault.ch_ids.remove(i); })
}

public(package) fun max_markets_in_vault<L, C>(vault: &Vault<L, C>): u64 {
    vault.vault_params.max_markets_in_vault
}

public(package) fun max_pending_orders_per_position<L, C>(vault: &Vault<L, C>): u64 {
    vault.vault_params.max_pending_orders_per_position
}

/// ADMIN caps are always valid; ASSISTANT caps only while they are still authorized.
fun has_authority<L, C, Role>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, Role>,
): bool {
    let role = type_name::with_defining_ids<Role>();
    cap.`for`() == vault.id.to_inner() && (
        role == authority::type_name_of!<ADMIN>() || (
            role == authority::type_name_of!<ASSISTANT>() &&
                vault.is_authority_cap_authorized<L, C, Role>(object::id(cap))
        )
    )
}

fun has_treasury_authority<L, C>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, TREASURY>,
): bool {
    cap.`for`() == vault.id.to_inner() &&
        vault.is_authority_cap_authorized<L, C, TREASURY>(object::id(cap))
}

/// Whether the vault's position in `clearing_house` is empty: no collateral left (at the
/// collateral's own precision), no base amount and no pending orders.
public(package) fun position_has_no_value<C>(
    clearing_house: &ClearingHouse<C>,
    account_id: u64,
): bool {
    let position = clearing_house.position(account_id);
    let (base_amount, _) = position.base_and_quote_amounts();
    let scaling_factor = clearing_house.market_params().scaling_factor();
    ifixed::to_balance(ifixed::abs(position.collateral()), scaling_factor) == 0 &&
        (base_amount == 0 && position.pending_order_count() == 0)
}

/// The vault's margin (collateral value plus unrealized PnL and funding) in one market, and the
/// margin requirement at `margin_ratio`. A non-positive margin counts as zero, or aborts when
/// `abort_if_negative` is set.
public(package) fun get_vault_margin_in_market<L, C>(
    _vault: &Vault<L, C>,
    clearing_house: &ClearingHouse<C>,
    account_id: u64,
    mark_price: u256,
    collateral_price: u256,
    margin_ratio: u256,
    collateral_haircut: u256,
    abort_if_negative: bool,
): (u256, u256) {
    let (cum_funding_rate_long, cum_funding_rate_short) =
        clearing_house.market_state().cum_funding_rates();
    let (margin, margin_requirement) = clearing_house
        .position(account_id)
        .compute_margin_with_fundings(
            collateral_price,
            mark_price,
            margin_ratio,
            cum_funding_rate_long,
            cum_funding_rate_short,
            collateral_haircut,
        );
    if (ifixed::less_than_eq(margin, 0)) {
        assert!(!abort_if_negative, errors::non_positive_market_margin());
        (0, margin_requirement)
    } else {
        (margin, margin_requirement)
    }
}

public(package) fun owner_fees_mut<L, C>(vault: &mut Vault<L, C>): &mut Balance<C> {
    dynamic_field::borrow_mut(&mut vault.id, keys::owner_fees_key())
}

public(package) fun owner_locked_lp_balance<L, C>(vault: &Vault<L, C>): &Balance<L> {
    dynamic_field::borrow(&vault.id, keys::owner_user_lp_coin_key())
}

public(package) fun owner_locked_lp_balance_mut<L, C>(vault: &mut Vault<L, C>): &mut Balance<L> {
    dynamic_field::borrow_mut(&mut vault.id, keys::owner_user_lp_coin_key())
}

public(package) fun withdraw_request_mut<L, C>(
    vault: &mut Vault<L, C>,
    sender: address,
): &mut WithdrawRequest<L> {
    dynamic_field::borrow_mut(&mut vault.id, keys::withdraw_request(sender))
}

public(package) fun add_yield<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    perps_registry: &Registry,
    coin_in: Coin<C>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    let account_cap = vault.account_cap();
    vault.assert_account_has_vault_authority(account);

    // Collateral deposited straight into the vault's account raises the value of every LP coin.
    let amount = coin_in.value();
    account.deposit_collateral(account_cap, perps_registry, coin_in);
    events::emit_add_yield_event(vault.id(), amount)
}

public(package) fun admin_pause_vault<L, C>(vault: &mut Vault<L, C>) {
    vault.assert_package_version();
    // A pause that never expires marks an admin pause (see `assert_vault_is_not_admin_paused`).
    vault.paused = option::some(u64::max_value!());
    events::emit_admin_pause_vault(vault.id())
}

public(package) fun admin_unpause_vault<L, C>(vault: &mut Vault<L, C>) {
    vault.assert_package_version();
    vault.paused = option::none();
    events::emit_admin_unpause_vault(vault.id())
}

public(package) fun freeze_vault<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    vault.assert_package_version();
    config.assert_is_active_package_freeze_guardian_cap(cap);

    // Park the current version and set an unreachable one, so every version check fails
    // until the vault is unfrozen.
    let resume_version = vault.version;
    dynamic_field::add(&mut vault.id, keys::frozen_version_key(), resume_version);
    vault.version = u64::max_value!();
    events::emit_froze(vault.id(), resume_version, object::id(cap))
}

public(package) fun unfreeze_vault<L, C>(
    vault: &mut Vault<L, C>,
    _: &AuthorityCap<PACKAGE, ADMIN>,
) {
    assert!(vault.is_frozen(), errors::not_frozen());

    let resume_version: u64 = dynamic_field::remove(&mut vault.id, keys::frozen_version_key());
    assert!(resume_version <= 1, errors::invalid_resume_version());
    vault.version = resume_version;
    events::emit_unfroze(vault.id(), resume_version)
}

public(package) fun admin_pause_vault_for_force_withdraw<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    clock: &Clock,
    withdraw_request_address: address,
) {
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    pause_for_force_withdraw!(vault, config, withdraw_request_address, clock.timestamp_ms())
}

public(package) fun pause_vault_for_force_withdraw<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    clock: &Clock,
    withdraw_request_address: address,
) {
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let now = clock.timestamp_ms();
    pause_for_force_withdraw!(vault, config, withdraw_request_address, now);
    // Anyone with a matured request can pause the vault, so it is rate limited.
    assert!(
        vault.last_paused_timestamp_ms +
            vault.vault_params.min_pause_vault_for_force_withdraw_frequency_ms <= now,
        errors::pause_vault_for_force_withdraw_too_frequent(),
    );
    vault.last_paused_timestamp_ms = now
}

public(package) fun resume_vault_for_force_withdraw<L, C>(vault: &mut Vault<L, C>, clock: &Clock) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    if (vault.paused.is_some_and!(|paused_until| clock.timestamp_ms() < *paused_until)) return;
    vault.paused = option::none()
}

public(package) fun withdraw_fees<L, C>(
    vault: &mut Vault<L, C>,
    amount_to_withdraw: u64,
    ctx: &mut TxContext,
): Coin<C> {
    let vault_id = vault.id();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let owner_fees = vault.owner_fees_mut();
    assert!(owner_fees.value() >= amount_to_withdraw, errors::not_enough_fees());
    let fees = owner_fees.split(amount_to_withdraw).into_coin(ctx);
    events::emit_withdraw_fees(vault_id, amount_to_withdraw);
    fees
}

public(package) fun upgrade_vault_version<L, C>(vault: &mut Vault<L, C>) {
    vault.assert_vault_is_not_admin_paused();

    let new_version = 1;
    assert!(new_version > vault.version, errors::bad_new_vault_version());
    vault.version = new_version;
    events::emit_upgrade_vault_version(vault.id(), new_version)
}

public(package) fun set_collateral_pfs_info<L, C>(
    vault: &mut Vault<L, C>,
    perps_registry: &Registry,
) {
    vault.assert_vault_is_not_admin_paused();

    let (collateral_storage_id, collateral_source_id, scaling_factor) =
        perps_registry.collateral_info<C>();
    vault.vault_params.collateral_storage_id = collateral_storage_id;
    vault.vault_params.collateral_source_id = collateral_source_id;
    vault.vault_params.scaling_factor = scaling_factor;
    events::emit_update_collateral_pfs_info(vault.id(), collateral_storage_id, collateral_source_id)
}

public(package) fun set_collateral_pfs_tolerance<L, C>(
    vault: &mut Vault<L, C>,
    collateral_pfs_tolerance: u64,
) {
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.collateral_pfs_tolerance = collateral_pfs_tolerance;
    events::emit_update_collateral_pfs_tolerance(vault.id(), collateral_pfs_tolerance)
}

public(package) fun set_min_pause_vault_for_force_withdraw_frequency_ms<L, C>(
    vault: &mut Vault<L, C>,
    min_pause_vault_for_force_withdraw_frequency_ms: u64,
) {
    let vault_id = vault.id();
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.min_pause_vault_for_force_withdraw_frequency_ms =
        min_pause_vault_for_force_withdraw_frequency_ms;
    events::emit_update_min_pause_vault_for_force_withdraw_frequency_ms(
        vault_id,
        min_pause_vault_for_force_withdraw_frequency_ms,
    )
}

public(package) fun set_min_force_withdraw_position_usd<L, C>(
    vault: &mut Vault<L, C>,
    min_force_withdraw_position_usd: u256,
) {
    let vault_id = vault.id();
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.min_force_withdraw_position_usd = min_force_withdraw_position_usd;
    events::emit_update_min_force_withdraw_position_usd(vault_id, min_force_withdraw_position_usd)
}

public(package) fun set_max_force_withdraw_mr_tolerance<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    max_force_withdraw_mr_tolerance: u256,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.max_force_withdraw_mr_tolerance = max_force_withdraw_mr_tolerance;
    events::emit_update_max_force_withdraw_mr_tolerance(vault_id, max_force_withdraw_mr_tolerance)
}

public(package) fun set_max_markets_in_vault<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    max_markets_in_vault: u64,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(
        max_markets_in_vault <= config.max_markets_in_vault(),
        errors::invalid_max_markets_in_vault(),
    );
    vault.vault_params.max_markets_in_vault = max_markets_in_vault;
    events::emit_max_markets_updated(vault_id, max_markets_in_vault)
}

public(package) fun admin_set_max_markets_in_vault<L, C>(
    vault: &mut Vault<L, C>,
    max_markets_in_vault: u64,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.max_markets_in_vault = max_markets_in_vault;
    events::emit_max_markets_updated(vault.id(), max_markets_in_vault)
}

public(package) fun set_max_pending_orders_per_position<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    max_pending_orders_per_position: u64,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(
        max_pending_orders_per_position <= config.max_pending_orders_per_position(),
        errors::invalid_max_pending_orders_per_position(),
    );
    vault.vault_params.max_pending_orders_per_position = max_pending_orders_per_position;
    events::emit_max_pending_orders_updated(vault_id, max_pending_orders_per_position)
}

public(package) fun set_owner_fee_rate<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    owner_fee_rate: u256,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(
        !ifixed::is_neg(owner_fee_rate) &&
            ifixed::less_than_eq(owner_fee_rate, config.max_owner_fee_rate()),
        errors::invalid_owner_fee_rate(),
    );
    vault.vault_params.owner_fee_rate = owner_fee_rate;
    events::emit_update_owner_fee_rate(vault_id, owner_fee_rate)
}

public(package) fun set_lock_period<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    lock_period: u64,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(lock_period <= config.max_lock_period(), errors::invalid_lock_period());
    vault.vault_params.lock_period = lock_period;
    events::emit_update_lock_period(vault_id, lock_period)
}

public(package) fun set_force_withdraw_delay<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
    force_withdraw_delay: u64,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(
        force_withdraw_delay <= config.max_force_withdraw_delay(),
        errors::invalid_force_withdraw_delay(),
    );
    vault.vault_params.force_withdraw_delay = force_withdraw_delay;
    events::emit_update_force_withdraw_delay(vault_id, force_withdraw_delay)
}

public(package) fun set_max_total_deposited_collateral<L, C>(
    vault: &mut Vault<L, C>,
    max_total_deposited_collateral: u64,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.vault_params.max_total_deposited_collateral = max_total_deposited_collateral;
    events::emit_update_max_total_deposited_collateral(vault_id, max_total_deposited_collateral)
}

public(package) fun clip_lock_period<L, C>(vault: &mut Vault<L, C>, config: &Config) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let max_lock_period = config.max_lock_period();
    if (vault.vault_params.lock_period <= max_lock_period) return;
    vault.vault_params.lock_period = max_lock_period;
    events::emit_update_lock_period(vault_id, max_lock_period)
}

public(package) fun clip_force_withdraw_delay<L, C>(vault: &mut Vault<L, C>, config: &Config) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let max_force_withdraw_delay = config.max_force_withdraw_delay();
    if (vault.vault_params.force_withdraw_delay <= max_force_withdraw_delay) return;
    vault.vault_params.force_withdraw_delay = max_force_withdraw_delay;
    events::emit_update_force_withdraw_delay(vault_id, max_force_withdraw_delay)
}

public(package) fun clip_owner_fee_rate<L, C>(vault: &mut Vault<L, C>, config: &Config) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let max_owner_fee_rate = config.max_owner_fee_rate();
    if (ifixed::less_than_eq(vault.vault_params.owner_fee_rate, max_owner_fee_rate)) return;
    vault.vault_params.owner_fee_rate = max_owner_fee_rate;
    events::emit_update_owner_fee_rate(vault_id, max_owner_fee_rate)
}

public(package) fun clip_min_owner_lock_usd<L, C>(vault: &mut Vault<L, C>, config: &Config) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    // Clamp the vault's value into the package-wide [min, max] range.
    let min_owner_lock_usd = config.min_owner_lock_usd();
    let max_owner_lock_usd = config.max_owner_lock_usd();
    let current = vault.vault_params.min_owner_lock_usd;
    let clipped = if (ifixed::less_than(current, min_owner_lock_usd)) min_owner_lock_usd
    else if (ifixed::greater_than(current, max_owner_lock_usd)) max_owner_lock_usd
    else return;
    vault.vault_params.min_owner_lock_usd = clipped;
    events::emit_update_min_owner_lock_usd(vault_id, clipped)
}

public(package) fun clip_max_markets_in_vault<L, C>(vault: &mut Vault<L, C>, config: &Config) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let max_markets_in_vault = config.max_markets_in_vault();
    if (vault.vault_params.max_markets_in_vault <= max_markets_in_vault) return;
    vault.vault_params.max_markets_in_vault = max_markets_in_vault;
    events::emit_max_markets_updated(vault_id, max_markets_in_vault)
}

public(package) fun clip_max_pending_orders_per_position<L, C>(
    vault: &mut Vault<L, C>,
    config: &Config,
) {
    let vault_id = vault.id();
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let max_pending_orders_per_position = config.max_pending_orders_per_position();
    if (vault.vault_params.max_pending_orders_per_position <= max_pending_orders_per_position) {
        return
    };
    vault.vault_params.max_pending_orders_per_position = max_pending_orders_per_position;
    events::emit_max_pending_orders_updated(vault_id, max_pending_orders_per_position)
}

public(package) fun new_vault_assistant_cap<L, C>(
    vault: &mut Vault<L, C>,
    authority_cap: &AuthorityCap<VAULT<L>, ADMIN>,
    config: &Config,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<L>, ASSISTANT> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    config.assert_package_version();
    vault.assert_vault_authority_cap_is_valid(authority_cap);

    let assistant_cap = authority::create_vault_assistant_cap<L>(&mut vault.id, ctx);
    let active_assistant_count: &mut u64 = dynamic_field::borrow_mut(
        &mut vault.id,
        keys::active_assistant_count_key(),
    );
    assert!(
        *active_assistant_count < config.max_assistants_per_vault(),
        errors::too_many_assistants(),
    );
    *active_assistant_count = *active_assistant_count + 1;
    cap_authority::authorize_cap(&mut vault.id, &assistant_cap);
    events::emit_create_vault_assistant_cap(vault.id(), object::id(&assistant_cap));
    assistant_cap
}

public(package) fun deauthorize_vault_authority_cap<L, C, Role>(
    vault: &mut Vault<L, C>,
    authority_cap: &AuthorityCap<VAULT<L>, ADMIN>,
    cap_id: ID,
) {
    vault.assert_vault_authority_cap_is_valid(authority_cap);
    authority::assert_is_not_admin<Role>();
    assert!(vault.is_authority_cap_authorized<L, C, Role>(cap_id), EInvalidVaultAuthorityCap);

    cap_authority::deauthorize_cap<VAULT<L>, Role>(&mut vault.id, cap_id);
    if (authority::type_name_of!<Role>() == authority::type_name_of!<ASSISTANT>()) {
        let active_assistant_count: &mut u64 = dynamic_field::borrow_mut(
            &mut vault.id,
            keys::active_assistant_count_key(),
        );
        *active_assistant_count = *active_assistant_count - 1
    };
    events::emit_revoked_vault_authority_cap(
        vault.id(),
        type_name::with_defining_ids<Role>(),
        cap_id,
    )
}

public(package) fun new_vault_treasury_cap<L, C>(
    vault: &mut Vault<L, C>,
    authority_cap: &AuthorityCap<VAULT<L>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VAULT<L>, TREASURY> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_vault_authority_cap_is_valid(authority_cap);

    let treasury_cap = authority::create_vault_treasury_cap<L>(&mut vault.id, ctx);
    cap_authority::authorize_cap(&mut vault.id, &treasury_cap);
    events::emit_create_vault_treasury_cap(vault.id(), object::id(&treasury_cap));
    treasury_cap
}

public fun user_lp_coin_info<L>(
    user_lp_coin: &UserLpCoin<L>,
): (u64, u64) {
    (user_lp_coin.lp_balance.value(), user_lp_coin.start_timestamp_ms)
}

public(package) fun join_user_lp_coin<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    config: &mut Config,
    other_user_lp_coin: UserLpCoin<L>,
) {
    config.unregister_user_lp_coin(other_user_lp_coin.id.to_inner());
    join_user_lp_coin_(user_lp_coin, other_user_lp_coin)
}

fun join_user_lp_coin_<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    other_user_lp_coin: UserLpCoin<L>,
) {
    let UserLpCoin { id, lp_balance, start_timestamp_ms, provided_value_usd } = other_user_lp_coin;
    user_lp_coin.lp_balance.join(lp_balance);
    // The merged coin keeps the later start, so joining can never shorten a lock period.
    if (start_timestamp_ms > user_lp_coin.start_timestamp_ms) {
        user_lp_coin.start_timestamp_ms = start_timestamp_ms
    };
    user_lp_coin.provided_value_usd = user_lp_coin.provided_value_usd + provided_value_usd;
    id.delete()
}

public(package) fun split_user_lp_coin<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    config: &mut Config,
    amount: u64,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    let user_lp_coin_id = user_lp_coin.id.to_inner();
    let vault_id = config.user_lp_coin_record(user_lp_coin_id).user_lp_coin_record_vault_id();
    let new_user_lp_coin = split_user_lp_coin_(user_lp_coin, amount, ctx);
    config.register_user_lp_coin(new_user_lp_coin.id.to_inner(), vault_id);
    new_user_lp_coin
}

fun split_user_lp_coin_<L>(
    user_lp_coin: &mut UserLpCoin<L>,
    amount: u64,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    // The split-off coin carries a pro-rata share of the provided value (the owner fee basis).
    let split_fraction = ifixed::div(
        ifixed::from_balance(amount, B9_SCALING),
        ifixed::from_balance(user_lp_coin.lp_balance.value(), B9_SCALING),
    );
    let split_value_usd = ifixed::mul(user_lp_coin.provided_value_usd, split_fraction);
    assert!(split_value_usd > 0, errors::invalid_split_amount());
    user_lp_coin.provided_value_usd = user_lp_coin.provided_value_usd - split_value_usd;
    UserLpCoin {
        id: object::new(ctx),
        lp_balance: user_lp_coin.lp_balance.split(amount),
        start_timestamp_ms: user_lp_coin.start_timestamp_ms,
        provided_value_usd: split_value_usd,
    }
}

fun create_deposit_session<L, C>(
    vault: Vault<L, C>,
    account: Account<C>,
    sender: address,
    balance: Balance<C>,
    timestamp_ms: u64,
    collateral_price: u256,
): DepositSession<L, C> {
    // Idle collateral in the account; each clearing house adds its margin during the session.
    let vault_balance_value = ifixed::mul(
        ifixed::from_balance(account.collateral_balance(), vault.vault_params.scaling_factor),
        collateral_price,
    );
    let ch_ids = vault.ch_ids();
    DepositSession {
        vault,
        account,
        sender,
        timestamp_ms,
        collateral_price,
        ch_ids,
        vault_balance_value,
        provided_balance: balance,
    }
}

public(package) fun start_deposit_session<L, C>(
    vault: Vault<L, C>,
    config: &Config,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    coin: Coin<C>,
    clock: &Clock,
    ctx: &TxContext,
): DepositSession<L, C> {
    vault.assert_package_version();
    config.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(&account);
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        vault.vault_params.collateral_storage_id,
    );

    let collateral_price = get_price(
        collateral_oracle,
        clock,
        vault.vault_params.collateral_source_id,
        vault.vault_params.collateral_pfs_tolerance,
    );
    assert_minimum_user_deposit(config, &vault, collateral_price, coin.value());
    let sender = ctx.sender();
    create_deposit_session(
        vault,
        account,
        sender,
        coin.into_balance(),
        clock.timestamp_ms(),
        collateral_price,
    )
}

#[allow(lint(share_owned))]
public(package) fun end_deposit_session<L, C>(
    deposit_session: DepositSession<L, C>,
    config: &mut Config,
    min_expected_lp_coin_out: u64,
    perps_registry: &Registry,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    let DepositSession {
        vault: mut vault,
        account: mut account,
        sender,
        timestamp_ms,
        collateral_price,
        ch_ids,
        vault_balance_value,
        provided_balance: mut provided_balance,
    } = deposit_session;
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    // Every clearing house must have been valued by `process_clearing_house_for_deposit`.
    assert!(ch_ids.length() == 0, errors::not_all_chs_processed());

    // LP to mint = LP supply * provided value / vault value, rounded down to LP precision.
    let scaling_factor = vault.vault_params.scaling_factor;
    let provided_amount = provided_balance.value();
    let provided_collateral = ifixed::from_balance(provided_amount, scaling_factor);
    let provided_value = ifixed::mul(provided_collateral, collateral_price);
    let lp_supply = ifixed::from_balance(vault.lp_supply_value(), B9_SCALING);
    let lp_to_mint = multiply_by_rational_ifixed(provided_value, lp_supply, vault_balance_value);
    assert!(!ifixed::is_neg(lp_to_mint), errors::user_lp_calculation_negative());
    let lp_amount = ifixed::to_balance(lp_to_mint, B9_SCALING);
    assert!(lp_amount != 0, errors::user_lp_calculation_zero());
    let lp_minted = ifixed::from_balance(lp_amount, B9_SCALING);

    // Only the collateral backing the rounded-down LP amount is taken, rounded up to collateral
    // precision; whatever is left of the provided balance is refunded below.
    let required_collateral = ifixed::div_up(
        ifixed::div_up(ifixed::mul_up(lp_minted, vault_balance_value), lp_supply),
        collateral_price,
    );
    let deposit_amount = if (ifixed::greater_than_eq(required_collateral, provided_collateral)) {
        provided_amount
    } else {
        let amount = ifixed::to_balance(required_collateral, scaling_factor);
        if (ifixed::from_balance(amount, scaling_factor) == required_collateral) amount
        else amount + 1
    };
    assert_minimum_user_deposit(config, &vault, collateral_price, deposit_amount);
    let deposit_value = ifixed::mul(
        ifixed::from_balance(deposit_amount, scaling_factor),
        collateral_price,
    );
    assert_deposit_cap_not_exceeded(
        &vault,
        ifixed::add(vault_balance_value, deposit_value),
        collateral_price,
    );
    let deposit = provided_balance.split(deposit_amount);
    account.deposit_collateral(vault.account_cap(), perps_registry, deposit.into_coin(ctx));

    // Rounding must not favour the depositor, and may cost them at most one collateral unit.
    let minted_lp_value = multiply_by_rational_ifixed(
        lp_minted,
        ifixed::add(vault_balance_value, deposit_value),
        ifixed::add(lp_supply, lp_minted),
    );
    assert!(
        ifixed::greater_than_eq(deposit_value, minted_lp_value),
        errors::deposit_rounding_loss_too_high(),
    );
    let rounding_loss = ifixed::sub(deposit_value, minted_lp_value);
    let one_collateral_unit_value = ifixed::mul(
        ifixed::from_balance(1, scaling_factor),
        collateral_price,
    );
    assert!(
        ifixed::less_than_eq(rounding_loss, one_collateral_unit_value),
        errors::deposit_rounding_loss_too_high(),
    );

    let lp_balance = vault.lp_supply.increase_supply(lp_amount);
    let lp_coin_out = lp_balance.value();
    assert!(lp_coin_out >= min_expected_lp_coin_out, errors::slippage_check());
    let user_lp_coin = UserLpCoin {
        id: object::new(ctx),
        lp_balance,
        start_timestamp_ms: timestamp_ms,
        provided_value_usd: deposit_value,
    };
    config.register_user_lp_coin(user_lp_coin.id.to_inner(), vault.id());
    events::emit_user_deposit(vault.id(), sender, deposit_amount, lp_coin_out, vault_balance_value);

    if (provided_balance.value() != 0) {
        transfer::public_transfer(provided_balance.into_coin(ctx), sender)
    } else {
        provided_balance.destroy_zero()
    };
    transfer::public_share_object(vault);
    transfer::public_share_object(account);
    user_lp_coin
}

public(package) fun set_deposit_session_sender<L, C>(
    deposit_session: &mut DepositSession<L, C>,
    sender: address,
) {
    deposit_session.vault.assert_vault_is_not_admin_paused();
    deposit_session.sender = sender
}

public(package) fun process_clearing_house_for_deposit<L, C>(
    deposit_session: &mut DepositSession<L, C>,
    mut clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    deposit_session.vault.assert_package_version();
    deposit_session.vault.assert_vault_is_not_admin_paused();
    let market_params = clearing_house.market_params();
    assert_base_price_feed_storage_is_correct(base_oracle, market_params.base_storage_id());

    // Each of the vault's clearing houses is valued exactly once per session.
    let unprocessed_ch_ids = &mut deposit_session.ch_ids;
    let mut idx = unprocessed_ch_ids.find_index!(|id| id == &object::id(&clearing_house));
    if (idx.is_none()) abort errors::clearing_house_id_not_found();
    let i = idx.extract();
    unprocessed_ch_ids.remove(i);

    // An empty position adds no value; the market is dropped from the vault instead.
    let account_id = deposit_session.account.account_id();
    if (position_has_no_value(&clearing_house, account_id)) {
        deposit_session.vault.remove_ch_id(object::id(&clearing_house));
        share_clearing_house(clearing_house);
        return
    };

    if (!clearing_house.is_market_paused()) {
        clearing_house.update_funding(base_oracle, clock)
    };
    // A settled market is valued at its settlement prices.
    let (is_settled, settlement_mark_price, settlement_collateral_price) =
        clearing_house.settlement_valuation_prices();
    let (mark_price, collateral_price) = if (is_settled) {
        (settlement_mark_price, settlement_collateral_price)
    } else {
        (clearing_house.mark_price(base_oracle, clock), deposit_session.collateral_price)
    };
    // Deposits count the market's margin without haircut and abort on a non-positive one.
    let (margin, _) = deposit_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        collateral_price,
        ifixed::from_u64(1),
        0,
        true,
    );
    deposit_session.vault_balance_value = ifixed::add(deposit_session.vault_balance_value, margin);
    share_clearing_house(clearing_house)
}

fun create_withdraw_session<L, C>(
    vault: Vault<L, C>,
    account: Account<C>,
    sender: address,
    user_lp_coin: UserLpCoin<L>,
    collateral_price: u256,
    can_force_process: bool,
    min_expected_balance_out: u64,
): WithdrawSession<L, C> {
    let ch_ids = vault.ch_ids();
    WithdrawSession {
        vault,
        account,
        sender,
        collateral_price,
        ch_ids,
        user_lp_coin,
        vault_balance_value: 0,
        accumulated_slippage: 0,
        accumulated_withdraw_dust: 0,
        can_force_process,
        min_expected_balance_out,
    }
}

#[allow(lint(self_transfer))]
public(package) fun create_withdraw_request<L, C>(
    vault: &mut Vault<L, C>,
    config: &mut Config,
    mut user_lp_coin: UserLpCoin<L>,
    lp_coin_amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(lp_coin_amount != 0, errors::withdraw_amount_zero());
    assert!(user_lp_coin.lp_balance.value() >= lp_coin_amount, errors::withdraw_amount_too_big());
    let sender = ctx.sender();
    vault.assert_withdraw_request_does_not_already_exist(sender);
    let now = clock.timestamp_ms();
    assert!(
        user_lp_coin.start_timestamp_ms + vault.vault_params.lock_period <= now,
        errors::lock_period_not_passed(),
    );

    // Only `lp_coin_amount` goes into the request; the rest of the coin goes back to the sender.
    let withdraw_request = if (user_lp_coin.lp_balance.value() == lp_coin_amount) {
        WithdrawRequest { user_lp_coin, request_timestamp_ms: now, min_expected_balance_out }
    } else {
        let requested_lp_coin = split_user_lp_coin_(&mut user_lp_coin, lp_coin_amount, ctx);
        config.register_user_lp_coin(requested_lp_coin.id.to_inner(), vault.id.to_inner());
        transfer::public_transfer(user_lp_coin, sender);
        WithdrawRequest {
            user_lp_coin: requested_lp_coin,
            request_timestamp_ms: now,
            min_expected_balance_out,
        }
    };
    dynamic_field::add(&mut vault.id, keys::withdraw_request(sender), withdraw_request);
    events::emit_create_withdraw_request(
        vault.id(),
        sender,
        lp_coin_amount,
        min_expected_balance_out,
    )
}

public(package) fun remove_withdraw_request<L, C>(
    vault: &mut Vault<L, C>,
    ctx: &TxContext,
): UserLpCoin<L> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    let sender = ctx.sender();
    vault.assert_withdraw_request_exists(sender);

    let WithdrawRequest {
        user_lp_coin,
        request_timestamp_ms: _,
        min_expected_balance_out: _,
    } = dynamic_field::remove(&mut vault.id, keys::withdraw_request(sender));
    let lp_coin_amount = user_lp_coin.lp_balance.value();
    events::emit_remove_withdraw_request(vault.id(), sender, lp_coin_amount);
    user_lp_coin
}

public(package) fun start_force_withdraw_session<L, C>(
    mut vault: Vault<L, C>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    address: address,
    clock: &Clock,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(&account);
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        vault.vault_params.collateral_storage_id,
    );

    let collateral_price = get_price(
        collateral_oracle,
        clock,
        vault.vault_params.collateral_source_id,
        vault.vault_params.collateral_pfs_tolerance,
    );
    vault.assert_withdraw_request_exists(address);
    let WithdrawRequest {
        user_lp_coin,
        request_timestamp_ms,
        min_expected_balance_out,
    } = dynamic_field::remove(&mut vault.id, keys::withdraw_request(address));
    let now = clock.timestamp_ms();
    assert!(
        request_timestamp_ms + vault.vault_params.force_withdraw_delay <= now,
        errors::force_withdraw_delay_not_passed(),
    );
    create_withdraw_session(
        vault,
        account,
        address,
        user_lp_coin,
        collateral_price,
        true,
        min_expected_balance_out,
    )
}

public(package) fun start_owner_process_withdraw_request<L, C>(
    mut vault: Vault<L, C>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    target_request_address: address,
    clock: &Clock,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(&account);
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        vault.vault_params.collateral_storage_id,
    );

    let collateral_price = get_price(
        collateral_oracle,
        clock,
        vault.vault_params.collateral_source_id,
        vault.vault_params.collateral_pfs_tolerance,
    );
    vault.assert_withdraw_request_exists(target_request_address);
    let WithdrawRequest {
        user_lp_coin,
        request_timestamp_ms: _,
        min_expected_balance_out,
    } = dynamic_field::remove(&mut vault.id, keys::withdraw_request(target_request_address));
    create_withdraw_session(
        vault,
        account,
        target_request_address,
        user_lp_coin,
        collateral_price,
        false,
        min_expected_balance_out,
    )
}

#[allow(lint(self_transfer))]
public(package) fun start_owner_withdraw_session<L, C>(
    vault: Vault<L, C>,
    config: &mut Config,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    mut user_lp_coin: UserLpCoin<L>,
    amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(amount != 0, errors::withdraw_amount_zero());
    let lp_coin_amount = user_lp_coin.lp_balance.value();
    assert!(amount <= lp_coin_amount, errors::withdraw_amount_too_big());
    vault.assert_account_has_vault_authority(&account);
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        vault.vault_params.collateral_storage_id,
    );

    let collateral_price = get_price(
        collateral_oracle,
        clock,
        vault.vault_params.collateral_source_id,
        vault.vault_params.collateral_pfs_tolerance,
    );
    let sender = ctx.sender();
    // Only `amount` is withdrawn; the remainder is split off and returned to the owner.
    if (amount < lp_coin_amount) {
        let remainder = split_user_lp_coin_(&mut user_lp_coin, lp_coin_amount - amount, ctx);
        config.register_user_lp_coin(remainder.id.to_inner(), vault.id.to_inner());
        transfer::public_transfer(remainder, sender)
    };
    create_withdraw_session(
        vault,
        account,
        sender,
        user_lp_coin,
        collateral_price,
        false,
        min_expected_balance_out,
    )
}

public(package) fun start_owner_locked_withdraw_session<L, C>(
    mut vault: Vault<L, C>,
    account: Account<C>,
    collateral_oracle: &PriceFeedStorage,
    amount: u64,
    min_expected_balance_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): WithdrawSession<L, C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    assert!(amount != 0, errors::withdraw_amount_zero());
    vault.assert_account_has_vault_authority(&account);
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        vault.vault_params.collateral_storage_id,
    );

    let collateral_price = get_price(
        collateral_oracle,
        clock,
        vault.vault_params.collateral_source_id,
        vault.vault_params.collateral_pfs_tolerance,
    );
    let sender = ctx.sender();
    let owner_locked_lp_coin = vault.take_owner_locked_user_lp_coin(amount, ctx);
    create_withdraw_session(
        vault,
        account,
        sender,
        owner_locked_lp_coin,
        collateral_price,
        false,
        min_expected_balance_out,
    )
}

public(package) fun end_withdraw_session_and_transfer_to_recipient<L, C>(
    withdraw_session: WithdrawSession<L, C>,
    config: &mut Config,
    perps_registry: &Registry,
    ctx: &mut TxContext,
) {
    withdraw_session.vault.assert_vault_is_not_admin_paused();
    config.assert_package_version();
    let recipient = withdraw_session.sender;
    let collateral_out = settle_withdraw_session!(withdraw_session, config, perps_registry, ctx);
    transfer::public_transfer(collateral_out, recipient)
}

public(package) fun end_withdraw_session<L, C>(
    withdraw_session: WithdrawSession<L, C>,
    config: &mut Config,
    perps_registry: &Registry,
    ctx: &mut TxContext,
): Coin<C> {
    withdraw_session.vault.assert_vault_is_not_admin_paused();
    config.assert_package_version();
    assert!(withdraw_session.sender == ctx.sender(), errors::invalid_sender());
    settle_withdraw_session!(withdraw_session, config, perps_registry, ctx)
}

public(package) fun set_new_withdraw_request_slippage<L, C>(
    vault: &mut Vault<L, C>,
    min_expected_balance_out: u64,
    ctx: &TxContext,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    let sender = ctx.sender();
    vault.assert_withdraw_request_exists(sender);

    let withdraw_request = vault.withdraw_request_mut(sender);
    withdraw_request.min_expected_balance_out = min_expected_balance_out;
    events::emit_user_withdraw_request_set_slippage(vault.id(), sender, min_expected_balance_out)
}

public(package) fun process_clearing_house_for_withdraw<L, C>(
    withdraw_session: &mut WithdrawSession<L, C>,
    mut clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    withdraw_session.vault.assert_package_version();
    withdraw_session.vault.assert_vault_is_not_admin_paused();
    assert!(!withdraw_session.can_force_process, errors::must_force_withdraw());
    let market_params = clearing_house.market_params();
    assert_base_price_feed_storage_is_correct(base_oracle, market_params.base_storage_id());

    // Each of the vault's clearing houses is valued exactly once per session.
    let unprocessed_ch_ids = &mut withdraw_session.ch_ids;
    let mut idx = unprocessed_ch_ids.find_index!(|id| id == &object::id(&clearing_house));
    if (idx.is_none()) abort errors::clearing_house_id_not_found();
    let i = idx.extract();
    unprocessed_ch_ids.remove(i);

    // An empty position adds no value; the market is dropped from the vault instead.
    let account_id = withdraw_session.account.account_id();
    if (position_has_no_value(&clearing_house, account_id)) {
        withdraw_session.vault.remove_ch_id(object::id(&clearing_house));
        share_clearing_house(clearing_house);
        return
    };

    if (!clearing_house.is_market_paused()) {
        clearing_house.update_funding(base_oracle, clock)
    };
    // A settled market is valued at its settlement prices.
    let (is_settled, settlement_mark_price, settlement_collateral_price) =
        clearing_house.settlement_valuation_prices();
    let (mark_price, collateral_price) = if (is_settled) {
        (settlement_mark_price, settlement_collateral_price)
    } else {
        (clearing_house.mark_price(base_oracle, clock), withdraw_session.collateral_price)
    };
    // Withdrawals count the market's margin (only the requirement depends on the ratio passed),
    // with a non-positive margin counted as zero.
    let initial_margin_ratio = clearing_house.market_params().margin_ratio_initial();
    let (margin, _) = withdraw_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        collateral_price,
        initial_margin_ratio,
        0,
        false,
    );
    withdraw_session.vault_balance_value = ifixed::add(
        withdraw_session.vault_balance_value,
        margin,
    );
    share_clearing_house(clearing_house)
}

/// Force-withdraw path for a matured withdraw request: the vault's position in `clearing_house`
/// is reduced (fully when small) so that the withdrawer's share of its margin can be freed,
/// with the realised slippage and fees charged to the withdrawer.
public(package) fun process_clearing_house_for_force_withdraw<L, C>(
    withdraw_session: &mut WithdrawSession<L, C>,
    mut clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    size_to_close: u64,
    order_ids: &vector<u128>,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
) {
    withdraw_session.vault.assert_package_version();
    withdraw_session.vault.assert_vault_is_not_admin_paused();
    assert!(withdraw_session.can_force_process, errors::cannot_force_withdraw());
    let market_params = clearing_house.market_params();
    assert_base_price_feed_storage_is_correct(base_oracle, market_params.base_storage_id());
    assert_collateral_price_feed_storage_is_correct(
        collateral_oracle,
        withdraw_session.vault.vault_params.collateral_storage_id,
    );
    // The collateral price must be the one the session was started with.
    assert!(
        get_price(
            collateral_oracle,
            clock,
            withdraw_session.vault.vault_params.collateral_source_id,
            withdraw_session.vault.vault_params.collateral_pfs_tolerance,
        ) == withdraw_session.collateral_price,
        errors::bad_oracle_price(),
    );

    let unprocessed_ch_ids = &mut withdraw_session.ch_ids;
    let mut idx = unprocessed_ch_ids.find_index!(|id| id == &object::id(&clearing_house));
    if (idx.is_none()) abort errors::clearing_house_id_not_found();
    let i = idx.extract();
    unprocessed_ch_ids.remove(i);

    let account_id = withdraw_session.account.account_id();
    if (position_has_no_value(&clearing_house, account_id)) {
        withdraw_session.vault.remove_ch_id(object::id(&clearing_house));
        share_clearing_house(clearing_house);
        return
    };

    // === Market state before closing ===

    clearing_house.update_funding(base_oracle, clock);
    let max_force_withdraw_mr_tolerance =
        withdraw_session.vault.vault_params.max_force_withdraw_mr_tolerance;
    let mark_price = clearing_house.mark_price(base_oracle, clock);
    let market_params = clearing_house.market_params();
    let collateral_haircut = market_params.collateral_haircut();
    let initial_margin_ratio = market_params.margin_ratio_initial();
    let (_, taker_fee) = market_params.maker_taker_fees();
    let (cum_funding_rate_long, cum_funding_rate_short) =
        clearing_house.market_state().cum_funding_rates();
    let priority_taker_fee = if (ctx.gas_price() > ctx.reference_gas_price()) {
        market::resolve_priority_taker_fee(market_params.priority_taker_fee())
    } else {
        0
    };
    let lot_size = ifixed::from_balance(market_params.lot_size(), B9_SCALING);
    let (margin_before, _) = withdraw_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        withdraw_session.collateral_price,
        initial_margin_ratio,
        0,
        false,
    );
    let (haircut_margin_before, _) = withdraw_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        withdraw_session.collateral_price,
        initial_margin_ratio,
        collateral_haircut,
        false,
    );
    let lp_share = ifixed::div(
        ifixed::from_balance(withdraw_session.user_lp_coin.lp_balance.value(), B9_SCALING),
        ifixed::from_balance(withdraw_session.vault.lp_supply_value(), B9_SCALING),
    );
    // The withdrawer's share of this market's margin, adjusted below by the close's slippage.
    let mut withdraw_value = ifixed::mul(margin_before, lp_share);

    // Target margin ratio after the withdrawal: the position's current margin ratio (including
    // pending orders and the haircut on funding), never below the initial margin ratio, so the
    // withdrawal leaves the remaining LPs' position no more leveraged than before.
    let position = clearing_house.position(account_id);
    let unrealized_pnl = position.unrealized_pnl(mark_price);
    let pending_funding = position.calculate_position_funding_internal(
        cum_funding_rate_long,
        cum_funding_rate_short,
    );
    let max_notional = ifixed::mul(position.abs_net_base(), mark_price);
    let (base_amount, _) = position.base_and_quote_amounts();
    let target_margin_ratio = if (base_amount != 0) {
        let collateral_value = ifixed::mul(
            position.collateral(),
            withdraw_session.collateral_price,
        );
        let haircut_funding = ifixed::sub(
            pending_funding,
            ifixed::mul(
                collateral_haircut,
                ifixed::sub(
                    ifixed::max(ifixed::add(collateral_value, pending_funding), 0),
                    ifixed::max(collateral_value, 0),
                ),
            ),
        );
        let pnl_margin_ratio = ifixed::add(
            ifixed::div(
                ifixed::add(unrealized_pnl, haircut_funding),
                ifixed::mul(ifixed::abs(base_amount), mark_price),
            ),
            initial_margin_ratio,
        );
        ifixed::max(
            ifixed::div(haircut_margin_before, max_notional),
            ifixed::max(pnl_margin_ratio, initial_margin_ratio),
        )
    } else {
        initial_margin_ratio
    };

    // Work at the market's initial margin ratio; the position's own one is restored at the end.
    let previous_initial_margin_ratio = position.effective_initial_margin_ratio(
        initial_margin_ratio,
    );
    clearing_house.set_position_initial_margin_ratio(
        withdraw_session.vault.account_cap(),
        &withdraw_session.account,
        initial_margin_ratio,
    );
    if (order_ids.length() != 0) {
        let _ = clearing_house.try_cancel_orders(
            withdraw_session.vault.account_cap(),
            &withdraw_session.account,
            order_ids,
        );
    };

    // === Close (part of) the position ===

    // All of the vault's pending orders must have been cancelled through `order_ids`.
    let position = clearing_house.position(account_id);
    let (base_amount, _) = position.base_and_quote_amounts();
    let (pending_asks, pending_bids) = position.pending_base_amounts_by_side();
    let pending_order_count = position.pending_order_count();
    assert!(
        pending_asks == 0 && (pending_bids == 0 && pending_order_count == 0),
        errors::wrong_order_ids_in_force_withdraw(),
    );
    let position_size = ifixed::to_balance(ifixed::abs(base_amount), B9_SCALING);
    // Positions worth at most `min_force_withdraw_position_usd` are closed completely.
    let is_small_position = ifixed::less_than_eq(
        ifixed::mul(ifixed::abs(base_amount), mark_price),
        withdraw_session.vault.vault_params.min_force_withdraw_position_usd,
    );
    let close_size = if (is_small_position) {
        position_size
    } else {
        u64::min(size_to_close, position_size)
    };
    if (close_size != 0) {
        let is_short = ifixed::is_neg(base_amount);
        let mut session = clearing_house.start_session(
            withdraw_session.vault.account_cap(),
            &mut withdraw_session.account,
            base_oracle,
            collateral_oracle,
            integrator_info,
            clock,
            ctx,
        );
        session.place_market_order(!is_short, close_size, true);
        let (clearing_house_after_close, session_summary) = session.end_session(
            withdraw_session.vault.account_cap(),
            &mut withdraw_session.account,
            false,
            false,
        );
        clearing_house = clearing_house_after_close;

        // Slippage = what the close gained over closing at the mark price, minus the fees paid.
        let execution_notional = ifixed::mul(
            ifixed::from_balance(close_size, B9_SCALING),
            session_summary.execution_price(!is_short),
        );
        let mark_notional = ifixed::mul(ifixed::from_balance(close_size, B9_SCALING), mark_price);
        let execution_gain = if (is_short) {
            ifixed::sub(mark_notional, execution_notional)
        } else {
            ifixed::sub(execution_notional, mark_notional)
        };
        let mut fee_rate = taker_fee;
        if (priority_taker_fee != 0) {
            fee_rate = ifixed::add(fee_rate, priority_taker_fee);
        };
        let integrator_fee = if (integrator_info.is_some()) {
            integrator_info.borrow().integrator_fee()
        } else {
            0
        };
        let fees = ifixed::mul(
            ifixed::add(fee_rate, integrator_fee),
            ifixed::abs(execution_notional),
        );
        let slippage = ifixed::sub(execution_gain, fees);
        withdraw_session.accumulated_slippage = ifixed::add(
            withdraw_session.accumulated_slippage,
            slippage,
        );
        withdraw_value = ifixed::add(withdraw_value, slippage);
    };
    assert!(!ifixed::is_neg(withdraw_value), errors::negative_amount_to_withdraw());

    // A small position is now closed: free all its collateral and drop the market.
    if (is_small_position) {
        let _ = clearing_house.deallocate_free_collateral(
            withdraw_session.vault.account_cap(),
            &mut withdraw_session.account,
            base_oracle,
            collateral_oracle,
            clock,
        );
        let ch_id = object::id(&clearing_house);
        let idx = withdraw_session.vault.ch_ids.find_index!(|id| *id == ch_id);
        idx.do!(|i| { withdraw_session.vault.ch_ids.remove(i); });
        clearing_house.set_position_initial_margin_ratio(
            withdraw_session.vault.account_cap(),
            &withdraw_session.account,
            previous_initial_margin_ratio,
        );
        share_clearing_house(clearing_house);
        return
    };

    // === Free the withdrawer's collateral ===

    // Deallocate up to the withdrawer's share, as far as the initial margin ratio allows. Only
    // when the full share is deallocated is its rounding remainder kept as dust.
    let collateral_to_withdraw = ifixed::to_balance(
        ifixed::div(withdraw_value, withdraw_session.collateral_price),
        withdraw_session.vault.vault_params.scaling_factor,
    );
    let max_deallocatable = clearing_house.collateral_to_deallocate_for_margin_ratio(
        account_id,
        base_oracle,
        collateral_oracle,
        clock,
        option::some(initial_margin_ratio),
    );
    let deallocate_amount = u64::min(collateral_to_withdraw, max_deallocatable);
    let withdraw_dust = if (deallocate_amount == collateral_to_withdraw) {
        ifixed::sub(
            withdraw_value,
            ifixed::mul(
                ifixed::from_balance(
                    deallocate_amount,
                    withdraw_session.vault.vault_params.scaling_factor,
                ),
                withdraw_session.collateral_price,
            ),
        )
    } else {
        0
    };
    if (deallocate_amount != 0) {
        let _ = clearing_house.deallocate_collateral(
            withdraw_session.vault.account_cap(),
            &mut withdraw_session.account,
            base_oracle,
            collateral_oracle,
            deallocate_amount,
            clock,
        );
    };

    // === Check the remaining position ===

    let (margin_after, _) = withdraw_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        withdraw_session.collateral_price,
        target_margin_ratio,
        0,
        false,
    );
    let (
        haircut_margin_after,
        margin_requirement_after,
    ) = withdraw_session.vault.get_vault_margin_in_market(
        &clearing_house,
        account_id,
        mark_price,
        withdraw_session.collateral_price,
        target_margin_ratio,
        collateral_haircut,
        false,
    );
    let position = clearing_house.position(account_id);
    let (base_after, quote_after) = position.base_and_quote_amounts();
    if (close_size != 0) {
        if (close_size == position_size) {
            // Fully closed: no significant collateral may be left in the market.
            assert!(
                ifixed::mul(position.collateral(), withdraw_session.collateral_price) <=
                    withdraw_session.vault.vault_params.min_force_withdraw_position_usd,
                errors::force_withdraw_collateral_leftover(),
            )
        } else {
            // Partly closed: the remaining position must meet the target margin ratio...
            let margin_ratio_after = ifixed::div(
                haircut_margin_after,
                ifixed::mul(ifixed::abs(base_after), mark_price),
            );
            assert!(
                ifixed::greater_than_eq(haircut_margin_after, margin_requirement_after),
                errors::force_withdraw_below_margin_ratio(),
            );
            // ...without closing more than needed: when it is above the target by more than the
            // tolerance, closing one lot less must have left it below the target.
            if (ifixed::less_than(
                ifixed::add(target_margin_ratio, max_force_withdraw_mr_tolerance),
                margin_ratio_after,
            )) {
                let entry_price = ifixed::div(quote_after, base_after);
                let is_short = ifixed::is_neg(base_after);
                // PnL realised by closing that last lot, which moved into collateral.
                let lot_pnl = if (is_short) {
                    ifixed::mul(lot_size, ifixed::sub(entry_price, mark_price))
                } else {
                    ifixed::mul(lot_size, ifixed::sub(mark_price, entry_price))
                };
                let collateral_value_with_funding = ifixed::add(
                    ifixed::mul(position.collateral(), withdraw_session.collateral_price),
                    position.calculate_position_funding_internal(
                        cum_funding_rate_long,
                        cum_funding_rate_short,
                    ),
                );
                // Without that lot's PnL in collateral, the haircut would have been smaller.
                let haircut_difference = ifixed::mul(
                    collateral_haircut,
                    ifixed::sub(
                        ifixed::max(collateral_value_with_funding, 0),
                        ifixed::max(ifixed::sub(collateral_value_with_funding, lot_pnl), 0),
                    ),
                );
                let margin_one_lot_less = ifixed::add(haircut_margin_after, haircut_difference);
                let base_one_lot_less = if (is_short) {
                    ifixed::sub(base_after, lot_size)
                } else {
                    ifixed::add(base_after, lot_size)
                };
                if (base_one_lot_less != 0) {
                    assert!(
                        ifixed::less_than(
                            ifixed::div(
                                margin_one_lot_less,
                                ifixed::mul(ifixed::abs(base_one_lot_less), mark_price),
                            ),
                            target_margin_ratio,
                        ),
                        errors::force_withdraw_above_margin_ratio_tolerance(),
                    )
                }
            }
        }
    } else {
        if (base_amount != 0) {
            assert!(
                ifixed::greater_than_eq(haircut_margin_after, margin_requirement_after),
                errors::force_withdraw_below_margin_ratio(),
            )
        }
    };

    // A position closed by now frees all its collateral and drops the market.
    if (base_after == 0) {
        let _ = clearing_house.deallocate_free_collateral(
            withdraw_session.vault.account_cap(),
            &mut withdraw_session.account,
            base_oracle,
            collateral_oracle,
            clock,
        );
        let ch_id = object::id(&clearing_house);
        let idx = withdraw_session.vault.ch_ids.find_index!(|id| *id == ch_id);
        idx.do!(|i| { withdraw_session.vault.ch_ids.remove(i); });
        clearing_house.set_position_initial_margin_ratio(
            withdraw_session.vault.account_cap(),
            &withdraw_session.account,
            previous_initial_margin_ratio,
        );
        share_clearing_house(clearing_house);
        return
    };

    withdraw_session.accumulated_withdraw_dust = ifixed::add(
        withdraw_session.accumulated_withdraw_dust,
        withdraw_dust,
    );
    withdraw_session.vault_balance_value = ifixed::add(
        withdraw_session.vault_balance_value,
        margin_after,
    );
    clearing_house.set_position_initial_margin_ratio(
        withdraw_session.vault.account_cap(),
        &withdraw_session.account,
        previous_initial_margin_ratio,
    );
    share_clearing_house(clearing_house)
}

/// Reads the oracle price, which must be no older than `oracle_tolerance` milliseconds.
fun get_price(
    oracle: &PriceFeedStorage,
    clock: &Clock,
    source_id: u16,
    oracle_tolerance: u64,
): u256 {
    let (price, timestamp_ms) = oracle.price_feed(source_id).price_and_timestamp_ms();
    let now = clock.timestamp_ms();
    assert!(now - now.min(oracle_tolerance) <= timestamp_ms, errors::bad_oracle_price());
    (price as u256)
}

/// Takes `amount` of the owner's locked LP into a temporary `UserLpCoin`, marked as owner-locked
/// by a maximal `provided_value_usd` (it never pays owner fees and has no config record).
fun take_owner_locked_user_lp_coin<L, C>(
    vault: &mut Vault<L, C>,
    amount: u64,
    ctx: &mut TxContext,
): UserLpCoin<L> {
    let owner_locked_lp = vault.owner_locked_lp_balance().value();
    assert!(amount <= owner_locked_lp, errors::withdraw_amount_too_big());
    let lp_balance = vault.owner_locked_lp_balance_mut().split(amount);
    UserLpCoin {
        id: object::new(ctx),
        lp_balance,
        start_timestamp_ms: 0,
        provided_value_usd: u256::max_value!(),
    }
}

/// `a * b / c` in fixed point; zero when `c` is zero.
fun multiply_by_rational_ifixed(a: u256, b: u256, c: u256): u256 {
    if (c == 0) return 0;
    ifixed::div(ifixed::mul(a, b), c)
}

public(package) fun assert_account_has_vault_authority<L, C>(
    vault: &Vault<L, C>,
    account: &Account<C>,
) {
    assert!(vault.account_cap().`for`() == object::id(account), EInvalidAccountAuthorityCap)
}

public(package) fun assert_package_version<L, C>(vault: &Vault<L, C>) {
    assert!(vault.version <= 1, errors::invalid_version())
}

public(package) fun assert_deposit_session_package_version<L, C>(
    deposit_session: &DepositSession<L, C>,
) {
    deposit_session.vault.assert_package_version()
}

public(package) fun assert_withdraw_session_package_version<L, C>(
    withdraw_session: &WithdrawSession<L, C>,
) {
    withdraw_session.vault.assert_package_version()
}

/// A force-withdraw pause is lifted once its timestamp has passed.
public(package) fun assert_vault_is_not_paused<L, C>(vault: &Vault<L, C>, clock: &Clock) {
    let paused = vault.paused;
    if (paused.is_some()) {
        assert!(paused.destroy_some() <= clock.timestamp_ms(), errors::vault_temporarily_paused())
    } else {
        paused.destroy_none()
    }
}

/// An admin pause is marked by a pause that never expires.
public(package) fun assert_vault_is_not_admin_paused<L, C>(vault: &Vault<L, C>) {
    let paused = vault.paused;
    if (paused.is_some()) {
        assert!(paused.destroy_some() != u64::max_value!(), errors::vault_temporarily_paused())
    } else {
        paused.destroy_none()
    }
}

public(package) fun assert_vault_authority_cap_is_valid<L, C, Role>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, Role>,
) {
    assert!(vault.has_authority(cap), EInvalidVaultAuthorityCap)
}

public(package) fun assert_vault_treasury_cap_is_valid<L, C>(
    vault: &Vault<L, C>,
    cap: &AuthorityCap<VAULT<L>, TREASURY>,
) {
    assert!(vault.has_treasury_authority(cap), EInvalidVaultAuthorityCap)
}

public(package) fun assert_withdraw_session_cap_has_authority<L, C, Role>(
    withdraw_session: &WithdrawSession<L, C>,
    authority_cap: &AuthorityCap<VAULT<L>, Role>,
) {
    withdraw_session.vault.assert_vault_authority_cap_is_valid(authority_cap)
}

fun assert_vault_creation_parameters_are_valid(
    config: &Config,
    lock_period: u64,
    owner_fee_rate: u256,
    force_withdraw_delay: u64,
) {
    assert!(lock_period <= config.max_lock_period(), errors::invalid_lock_period());
    assert!(
        force_withdraw_delay <= config.max_force_withdraw_delay(),
        errors::invalid_force_withdraw_delay(),
    );
    assert!(
        !ifixed::is_neg(owner_fee_rate) &&
            ifixed::less_than_eq(owner_fee_rate, config.max_owner_fee_rate()),
        errors::invalid_owner_fee_rate(),
    )
}

fun assert_minimum_owner_locked_liquidity_with_oracle(
    config: &Config,
    collateral_oracle: &PriceFeedStorage,
    collateral_source_id: u16,
    collateral_pfs_tolerance: u64,
    clock: &Clock,
    amount: u64,
    scaling_factor: u256,
) {
    let collateral = ifixed::from_balance(amount, scaling_factor);
    let price = get_price(collateral_oracle, clock, collateral_source_id, collateral_pfs_tolerance);
    let value_usd = ifixed::mul(collateral, price);
    assert!(
        ifixed::greater_than_eq(value_usd, config.min_owner_lock_usd()),
        errors::owner_locked_amount_not_enough(),
    );
    assert!(
        ifixed::less_than_eq(value_usd, config.max_owner_lock_usd()),
        errors::owner_locked_amount_too_big(),
    )
}

fun assert_minimum_user_deposit<L, C>(
    config: &Config,
    vault: &Vault<L, C>,
    collateral_price: u256,
    amount: u64,
) {
    assert!(
        ifixed::greater_than_eq(
            ifixed::mul(
                ifixed::from_balance(amount, vault.vault_params.scaling_factor),
                collateral_price,
            ),
            config.min_deposit_usd(),
        ),
        errors::user_deposit_amount_not_enough(),
    )
}

fun assert_deposit_cap_not_exceeded<L, C>(
    vault: &Vault<L, C>,
    total_vault_balance_value: u256,
    collateral_price: u256,
) {
    let max_total_deposited_value = ifixed::mul(
        ifixed::from_balance(
            vault.vault_params.max_total_deposited_collateral,
            vault.vault_params.scaling_factor,
        ),
        collateral_price,
    );
    assert!(
        ifixed::less_than_eq(total_vault_balance_value, max_total_deposited_value),
        errors::exceeding_max_total_deposited_collateral(),
    )
}

fun assert_collateral_price_feed_storage_is_correct(
    collateral_oracle: &PriceFeedStorage,
    collateral_storage_id: u32,
) {
    assert!(
        collateral_storage_id == collateral_oracle.storage_id(),
        errors::wrong_collateral_oracle(),
    )
}

fun assert_base_price_feed_storage_is_correct(
    base_oracle: &PriceFeedStorage,
    base_storage_id: u32,
) {
    assert!(base_storage_id == base_oracle.storage_id(), errors::wrong_base_oracle())
}

fun assert_withdraw_request_exists<L, C>(
    vault: &Vault<L, C>,
    sender: address,
) {
    assert!(
        dynamic_field::exists(&vault.id, keys::withdraw_request(sender)),
        errors::withdraw_request_does_not_exist(),
    )
}

fun assert_withdraw_request_does_not_already_exist<L, C>(
    vault: &Vault<L, C>,
    sender: address,
) {
    assert!(
        !dynamic_field::exists(&vault.id, keys::withdraw_request(sender)),
        errors::withdraw_request_already_exists(),
    )
}
