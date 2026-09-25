// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::perpetuals_api;

use haneul::clock::Clock;
use haneul::coin::Coin;
use haneul::haneul::HANEUL;
use market_making_vault::errors;
use market_making_vault::vault::{Self, Vault};
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::{Account, IntegratorInfo};
use perpetuals::clearing_house::{ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals::stop_orders;
use perpetuals::twap_orders::{Self, TWAPOrderDetails};

// === Private macros reconstructed from repeated inlined code (not stored on-chain) ===

/// Keeps `vault.ch_ids` in sync with the vault's position in `clearing_house`: the clearing
/// house is dropped from the list once the position holds no value (no collateral, base or
/// pending orders), and added (bounded by `max_markets_in_vault`) otherwise.
macro fun update_ch_ids<$L, $C>(
    $vault: &mut Vault<$L, $C>,
    $clearing_house: &ClearingHouse<$C>,
    $account_id: u64,
) {
    let (vault, clearing_house) = ($vault, $clearing_house);
    let has_no_value = vault::position_has_no_value(clearing_house, $account_id);
    let ch_id = object::id(clearing_house);
    let ch_ids = vault.ch_ids_mut();
    if (has_no_value) {
        let idx = ch_ids.find_index!(|e| *e == ch_id);
        idx.do!(|i| { ch_ids.remove(i); })
    } else {
        let idx = ch_ids.find_index!(|e| *e == ch_id);
        if (idx.is_none()) {
            ch_ids.push_back(ch_id);
            assert!(ch_ids.length() <= vault.max_markets_in_vault(), errors::max_markets_exceeded())
        }
    }
}

// === Functions ===

public(package) fun allocate_collateral_to_position<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    amount: u64,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);
    assert!(amount <= account.collateral_balance(), errors::not_enough_collateral_balance());

    clearing_house.allocate_collateral(vault.account_cap(), account, amount);
    update_ch_ids!(vault, clearing_house, account.account_id())
}

public(package) fun deallocate_collateral_from_position<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount: Option<u64>,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);

    // Without an explicit amount, all collateral not needed as margin is withdrawn.
    if (amount.is_some()) {
        let account_cap = vault.account_cap();
        let _ = clearing_house.deallocate_collateral(
            account_cap,
            account,
            base_oracle,
            collateral_oracle,
            amount.destroy_some(),
            clock,
        );
    } else {
        let account_cap = vault.account_cap();
        let _ = clearing_house.deallocate_free_collateral(
            account_cap,
            account,
            base_oracle,
            collateral_oracle,
            clock,
        );
    };
    update_ch_ids!(vault, clearing_house, account.account_id())
}

public(package) fun close_position_at_settlement_prices<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    clearing_house.close_position_at_settlement_prices(account, order_ids);
    update_ch_ids!(vault, clearing_house, account.account_id())
}

public(package) fun reconcile_clearing_house<L, C>(
    vault: &mut Vault<L, C>,
    account: &Account<C>,
    clearing_house: &ClearingHouse<C>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    let account_id = account.account_id();
    if (clearing_house.exists_position(account_id)) {
        update_ch_ids!(vault, clearing_house, account_id)
    } else {
        let ch_id = object::id(clearing_house);
        let ch_ids = vault.ch_ids_mut();
        let idx = ch_ids.find_index!(|e| *e == ch_id);
        idx.do!(|i| { ch_ids.remove(i); })
    }
}

public(package) fun remove_empty_clearing_house<L, C>(
    vault: &mut Vault<L, C>,
    account: &Account<C>,
    clearing_house: &ClearingHouse<C>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    let account_id = account.account_id();
    assert!(
        !clearing_house.exists_position(account_id) ||
            vault::position_has_no_value(clearing_house, account_id),
        errors::clearing_house_not_empty(),
    );
    vault.remove_ch_id(object::id(clearing_house))
}

public(package) fun place_market_order<L, C>(
    vault: &mut Vault<L, C>,
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
    vault.assert_vault_is_not_paused(clock);

    let mut session = clearing_house.start_session(
        vault.account_cap(),
        account,
        base_oracle,
        collateral_oracle,
        integrator_info,
        clock,
        ctx,
    );
    session.place_market_order(side, size, reduce_only);
    let (clearing_house, _) = session.end_session(vault.account_cap(), account, false, false);
    update_ch_ids!(vault, &clearing_house, account.account_id());
    clearing_house
}

public(package) fun place_limit_order<L, C>(
    vault: &mut Vault<L, C>,
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
    vault.assert_vault_is_not_paused(clock);

    let mut session = clearing_house.start_session(
        vault.account_cap(),
        account,
        base_oracle,
        collateral_oracle,
        integrator_info,
        clock,
        ctx,
    );
    let order_id = session.place_limit_order(
        side,
        size,
        price,
        order_type,
        client_order_id,
        reduce_only,
        expiration_timestamp_ms,
    );
    let (clearing_house, _) = session.end_session(vault.account_cap(), account, false, false);
    // Only an order left resting on the book counts towards the pending order limit.
    if (order_id.is_some()) {
        assert_pending_orders_within_limit(vault, &clearing_house, account.account_id())
    };
    update_ch_ids!(vault, &clearing_house, account.account_id());
    (clearing_house, order_id)
}

public(package) fun cancel_orders<L, C>(
    vault: &mut Vault<L, C>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
    clock: &Clock,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);

    let account_cap = vault.account_cap();
    let mut ids = vector[];
    order_ids.do_ref!(|order_id| ids.push_back(*order_id));
    clearing_house.cancel_orders(account_cap, account, ids);
    if (order_ids.length() != 0) {
        update_ch_ids!(vault, clearing_house, account.account_id())
    }
}

public(package) fun try_cancel_orders<L, C>(
    vault: &mut Vault<L, C>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    order_ids: &vector<u128>,
    clock: &Clock,
): vector<bool> {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);

    let cancelled = clearing_house.try_cancel_orders(vault.account_cap(), account, order_ids);
    let mut any_cancelled = false;
    cancelled.do_ref!(|was_cancelled| {
        if (*was_cancelled) {
            any_cancelled = true;
        };
    });
    if (any_cancelled) {
        update_ch_ids!(vault, clearing_house, account.account_id())
    };
    cancelled
}

public(package) fun liquidate<L, C>(
    vault: &mut Vault<L, C>,
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
    vault.assert_vault_is_not_paused(clock);

    let mut session = clearing_house.start_session(
        vault.account_cap(),
        account,
        base_oracle,
        collateral_oracle,
        integrator_info,
        clock,
        ctx,
    );
    session.liquidate(liqee_account_id, cancel_order_ids);
    let (clearing_house, _) = session.end_session(vault.account_cap(), account, false, false);
    update_ch_ids!(vault, &clearing_house, account.account_id());
    share_clearing_house(clearing_house)
}

public(package) fun set_position_initial_margin_ratio<L, C>(
    vault: &Vault<L, C>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
    initial_margin_ratio: u256,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let account_cap = vault.account_cap();
    clearing_house.set_position_initial_margin_ratio(account_cap, account, initial_margin_ratio)
}

public(package) fun create_market_position<L, C>(
    vault: &Vault<L, C>,
    account: &Account<C>,
    clearing_house: &mut ClearingHouse<C>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let account_cap = vault.account_cap();
    let account_id = account.account_id();
    if (!clearing_house.exists_position(account_id)) {
        clearing_house.create_market_position(account_cap, account)
    }
}

public(package) fun start_perpetuals_session<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext,
): SessionHotPotato<C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);

    clearing_house.start_session(
        vault.account_cap(),
        account,
        base_oracle,
        collateral_oracle,
        integrator_info,
        clock,
        ctx,
    )
}

public(package) fun end_perpetuals_session<L, C>(
    vault: &mut Vault<L, C>,
    account: &mut Account<C>,
    hot_potato: SessionHotPotato<C>,
    allocate_missing_margin: bool,
    deallocate_free_collateral: bool,
): ClearingHouse<C> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    let (clearing_house, _) = hot_potato.end_session(
        vault.account_cap(),
        account,
        allocate_missing_margin,
        deallocate_free_collateral,
    );
    let account_id = account.account_id();
    if (clearing_house.exists_position(account_id)) {
        assert_pending_orders_within_limit(vault, &clearing_house, account_id)
    };
    update_ch_ids!(vault, &clearing_house, account_id);
    clearing_house
}

public(package) fun create_stop_order_ticket<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    executors: vector<address>,
    gas: Coin<HANEUL>,
    stop_order_type: u64,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext,
): ID {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let account_cap = vault.account_cap();
    stop_orders::create_stop_order_ticket(
        account,
        account_cap,
        registry,
        executors,
        option::some(vault.execution_domain()),
        gas,
        stop_order_type,
        encrypted_details,
        ctx,
    )
}

public(package) fun edit_stop_order_ticket_details<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let account_cap = vault.account_cap();
    stop_orders::edit_stop_order_ticket_details(
        account,
        account_cap,
        registry,
        stop_order_ticket_id,
        encrypted_details,
    )
}

public(package) fun edit_stop_order_ticket_executors<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    executors: vector<address>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    let account_cap = vault.account_cap();
    stop_orders::edit_stop_order_ticket_executors(
        account,
        account_cap,
        registry,
        stop_order_ticket_id,
        executors,
    )
}

public(package) fun delete_stop_order_ticket<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    let executor = vault.executor(ctx);
    stop_orders::cancel_stop_order_ticket(account, registry, stop_order_ticket_id, &executor, ctx)
}

public(package) fun user_delete_stop_order_ticket<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    stop_order_ticket_id: ID,
    ctx: &mut TxContext,
): Coin<HANEUL> {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();

    stop_orders::cancel(account, vault.account_cap(), registry, stop_order_ticket_id, ctx)
}

public(package) fun create_twap_order_ticket<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    clearing_house: &ClearingHouse<C>,
    executors: vector<address>,
    gas: Coin<HANEUL>,
    encrypted_details: vector<u8>,
    ctx: &mut TxContext,
): ID {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    twap_orders::create_twap_order_ticket(
        account,
        vault.account_cap(),
        clearing_house,
        executors,
        option::some(vault.execution_domain()),
        gas,
        encrypted_details,
        ctx,
    )
}

public(package) fun edit_twap_order_ticket_details<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    encrypted_details: vector<u8>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    twap_orders::set_details(
        account,
        vault.account_cap(),
        registry,
        twap_order_ticket_id,
        encrypted_details,
    )
}

public(package) fun edit_twap_order_ticket_executors<L, C>(
    vault: &Vault<L, C>,
    account: &mut Account<C>,
    registry: &Registry,
    twap_order_ticket_id: ID,
    executors: vector<address>,
) {
    vault.assert_package_version();
    vault.assert_vault_is_not_admin_paused();
    vault.assert_account_has_vault_authority(account);

    twap_orders::set_executors(
        account,
        vault.account_cap(),
        registry,
        twap_order_ticket_id,
        executors,
    )
}

public(package) fun execute_twap_order<L, C>(
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
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let mut clearing_house = clearing_house;
    let executor = vault.executor(ctx);
    let account_cap = vault.account_cap();
    let account_id = account.account_id();
    if (!clearing_house.exists_position(account_id)) {
        clearing_house.create_market_position(account_cap, account)
    };
    let (summary, gas, clearing_house) = twap_orders::execute(
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        twap_order_ticket_id,
        new_details,
        amount,
        clock,
        &executor,
        ctx,
    );
    update_ch_ids!(vault, &clearing_house, account.account_id());
    (summary, gas, clearing_house)
}

public(package) fun finalize_twap_order<L, C>(
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
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let executor = vault.executor(ctx);
    let gas = twap_orders::finalize(
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        clock,
        twap_order_ticket_id,
        new_details,
        &executor,
        ctx,
    );
    let account_id = account.account_id();
    if (clearing_house.exists_position(account_id)) {
        update_ch_ids!(vault, clearing_house, account_id)
    };
    gas
}

public(package) fun cancel_twap_order<L, C>(
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
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let executor = vault.executor(ctx);
    let gas = twap_orders::cancel(
        account,
        clearing_house,
        base_oracle,
        collateral_oracle,
        twap_order_ticket_id,
        clock,
        &executor,
        ctx,
    );
    let account_id = account.account_id();
    if (clearing_house.exists_position(account_id)) {
        update_ch_ids!(vault, clearing_house, account_id)
    };
    gas
}

public(package) fun user_cancel_twap_order<L, C>(
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
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let gas = twap_orders::user_cancel_twap_order(
        account,
        vault.account_cap(),
        clearing_house,
        base_oracle,
        collateral_oracle,
        twap_order_ticket_id,
        clock,
        ctx,
    );
    let account_id = account.account_id();
    if (clearing_house.exists_position(account_id)) {
        update_ch_ids!(vault, clearing_house, account_id)
    };
    gas
}

public(package) fun place_stop_order_sltp<L, C>(
    vault: &mut Vault<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
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
    ctx: &mut TxContext,
): (SessionSummary, Coin<HANEUL>, ClearingHouse<C>) {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let mut clearing_house = clearing_house;
    let executor = vault.executor(ctx);
    let account_cap = vault.account_cap();
    let account_id = account.account_id();
    if (!clearing_house.exists_position(account_id)) {
        clearing_house.create_market_position(account_cap, account)
    };
    let (summary, gas, clearing_house) = stop_orders::place_stop_order_sltp(
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
        &executor,
        ctx,
    );
    if (is_limit_order) {
        assert_pending_orders_within_limit(vault, &clearing_house, account_id)
    };
    update_ch_ids!(vault, &clearing_house, account_id);
    (summary, gas, clearing_house)
}

public(package) fun place_stop_order_standalone<L, C>(
    vault: &mut Vault<L, C>,
    clearing_house: ClearingHouse<C>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
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
    ctx: &mut TxContext,
): (SessionSummary, Coin<HANEUL>, ClearingHouse<C>) {
    vault.assert_package_version();
    vault.assert_vault_is_not_paused(clock);
    vault.assert_account_has_vault_authority(account);

    let mut clearing_house = clearing_house;
    let executor = vault.executor(ctx);
    let account_cap = vault.account_cap();
    let account_id = account.account_id();
    if (!clearing_house.exists_position(account_id)) {
        clearing_house.create_market_position(account_cap, account)
    };
    let (summary, gas, clearing_house) = stop_orders::place_stop_order_standalone(
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
        &executor,
        ctx,
    );
    if (is_limit_order) {
        assert_pending_orders_within_limit(vault, &clearing_house, account_id)
    };
    update_ch_ids!(vault, &clearing_house, account_id);
    (summary, gas, clearing_house)
}

fun share_clearing_house<C>(clearing_house: ClearingHouse<C>) {
    clearing_house.share()
}

fun assert_pending_orders_within_limit<L, C>(
    vault: &Vault<L, C>,
    clearing_house: &ClearingHouse<C>,
    account_id: u64,
) {
    assert!(
        clearing_house.position(account_id).pending_order_count() <=
            vault.max_pending_orders_per_position(),
        errors::max_pending_orders_exceeded(),
    )
}
