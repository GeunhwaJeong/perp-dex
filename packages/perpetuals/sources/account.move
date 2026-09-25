// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::account;

use authority_cap::authority::{ADMIN, ASSISTANT, AuthorityCap};
use haneul::balance::{Self, Balance};
use haneul::coin::{Self, Coin};
use haneul::derived_object;
use haneul::dynamic_field;
use haneul::transfer::Receiving;
use ifixed::ifixed;
use perpetuals::authority::{Self, ACCOUNT};
use perpetuals::events;
use perpetuals::keys;
use perpetuals::registry::Registry;
use std::type_name;

// === Errors and constants (original names from the published interface) ===

macro fun invalid_account_cap(): u64 { 4000 }
macro fun invalid_integrator_fee(): u64 { 4001 }
macro fun collateral_is_not_registered(): u64 { 4002 }
macro fun invalid_share_policy(): u64 { 4003 }
macro fun order_invalid_account(): u64 { 4004 }
macro fun too_many_assistants_per_account(): u64 { 4005 }

// === Types ===

public struct IntegratorConfig has store { max_integrator_fee_b9: u32 }

public struct IntegratorInfo has copy, drop, store { integrator_id: u32, integrator_fee: u32 }

public struct AccountSharePolicy(ID)

public struct Account<phantom T> has key, store {
    id: UID,
    account_id: u64,
    collateral: Balance<T>,
    active_assistants: vector<ID>,
}

// === Functions ===

public fun max_integrator_fee_b9(config: &IntegratorConfig): u32 {
    config.max_integrator_fee_b9
}

public fun create_integrator_info(
    integrator_id: u32,
    integrator_fee_b9: u32,
): Option<IntegratorInfo> {
    // The fee is expressed in billionths: at most 1%.
    assert!(
        integrator_fee_b9 != 0 && integrator_fee_b9 <= 10_000_000,
        invalid_integrator_fee!(),
    );
    option::some(IntegratorInfo { integrator_id, integrator_fee: integrator_fee_b9 })
}

public fun integrator_id(info: &IntegratorInfo): u32 {
    info.integrator_id
}

public fun integrator_fee_b9(info: &IntegratorInfo): u32 {
    info.integrator_fee
}

public fun integrator_fee(info: &IntegratorInfo): u256 {
    ifixed::from_balance((info.integrator_fee as u64), 1_000_000_000)
}

public fun create_account<T>(
    registry: &mut Registry,
    ctx: &mut TxContext,
): (Account<T>, AccountSharePolicy, AuthorityCap<ACCOUNT, ADMIN>) {
    registry.assert_package_version();
    assert!(registry.is_collateral_registered<T>(), collateral_is_not_registered!());

    let account_id = registry.inc_account_id();
    let mut account = Account<T> {
        id: derived_object::claim(registry.borrow_mut_id(), keys::account(account_id)),
        account_id,
        collateral: balance::zero(),
        active_assistants: vector[],
    };
    let account_obj_id = account.id.to_inner();
    let share_policy = AccountSharePolicy(account_obj_id);
    let admin_cap = authority::create_account_admin_cap(&mut account.id, account_obj_id);

    events::e01<T>(account_obj_id, ctx.sender(), account_id);
    (account, share_policy, admin_cap)
}

public fun create_and_share_account<T>(
    registry: &mut Registry,
    ctx: &mut TxContext,
): AuthorityCap<ACCOUNT, ADMIN> {
    let (account, share_policy, admin_cap) = create_account<T>(registry, ctx);
    consume_policy_and_share_account(account, share_policy);
    admin_cap
}

#[allow(lint(custom_state_change, share_owned))]
public fun consume_policy_and_share_account<T>(
    account: Account<T>,
    share_policy: AccountSharePolicy,
) {
    let AccountSharePolicy(account_obj_id) = share_policy;
    assert!(account.id.to_inner() == account_obj_id, invalid_share_policy!());
    transfer::share_object(account)
}

public fun account_id<T>(account: &Account<T>): u64 {
    account.account_id
}

public fun collateral_balance<T>(account: &Account<T>): u64 {
    account.collateral.value()
}

public(package) fun borrow_mut_collateral<T>(account: &mut Account<T>): &mut Balance<T> {
    &mut account.collateral
}

public fun has_order_ticket<T>(
    account: &Account<T>,
    ticket_id: ID,
): bool {
    dynamic_field::exists(&account.id, keys::order_ticket(ticket_id))
}

public(package) fun borrow_mut_order_ticket<T, Ticket: key + store>(
    account: &mut Account<T>,
    ticket_id: ID,
): &mut Ticket {
    dynamic_field::borrow_mut(&mut account.id, keys::order_ticket(ticket_id))
}

public fun integrator_config<T>(
    account: &Account<T>,
    integrator_id: u32,
): &IntegratorConfig {
    dynamic_field::borrow(&account.id, keys::integrator_config(integrator_id))
}

public(package) fun add_order_ticket<T, Ticket: key + store>(
    account: &mut Account<T>,
    ticket: Ticket,
): ID {
    let ticket_id = object::id(&ticket);
    dynamic_field::add(&mut account.id, keys::order_ticket(ticket_id), ticket);
    ticket_id
}

public(package) fun remove_order_ticket<T, Ticket: key + store>(
    account: &mut Account<T>,
    ticket_id: ID,
): Ticket {
    dynamic_field::remove(&mut account.id, keys::order_ticket(ticket_id))
}

public fun withdraw_collateral<T>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry: &Registry,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    if (amount == 0) {
        return coin::zero(ctx)
    };

    let collateral = coin::take(&mut account.collateral, amount, ctx);
    events::e27<T>(account.account_id, amount);
    collateral
}

public fun new_assistant_account_cap<T>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry: &mut Registry,
    ctx: &mut TxContext,
): AuthorityCap<ACCOUNT, ASSISTANT> {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    assert!(
        account.active_assistants.length() < registry.config().max_assistants_per_account(),
        too_many_assistants_per_account!(),
    );

    let assistant_cap = authority::create_account_assistant_cap(cap, registry.borrow_mut_id(), ctx);
    let assistant_cap_id = object::id(&assistant_cap);
    account.active_assistants.push_back(assistant_cap_id);
    registry.register_account_assistant_cap(&assistant_cap);
    assistant_cap
}

public fun revoke_assistant_account_cap<T>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry: &mut Registry,
    assistant_cap_id: ID,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    assert!(account.active_assistants.contains(&assistant_cap_id), invalid_account_cap!());
    account.revoke_assistant_account_cap_(assistant_cap_id);
    registry.unregister_account_assistant_cap_if_registered(assistant_cap_id)
}

public fun destroy_assistant_account_cap<T>(
    account: &mut Account<T>,
    cap: AuthorityCap<ACCOUNT, ASSISTANT>,
    registry: &mut Registry,
) {
    registry.assert_package_version();
    assert!(cap.`for`() == account.id.to_inner(), invalid_account_cap!());
    let cap_id = object::id(&cap);
    account.revoke_assistant_account_cap_(cap_id);
    registry.unregister_account_assistant_cap_if_registered(cap_id);
    authority::destroy_account_assistant_cap(cap)
}

public fun deposit_collateral<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    coin: Coin<T>,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    let amount = coin.value();
    if (amount == 0) {
        coin.destroy_zero();
        return
    };

    account.collateral.join(coin.into_balance());
    events::e02<T>(account.account_id, amount)
}

public fun receive_from_account<T, ADMIN_OR_ASSISTANT, Obj: key + store>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    receiving: Receiving<Obj>,
): Obj {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    transfer::public_receive(&mut account.id, receiving)
}

public fun add_integrator_config<T, ADMIN_OR_ASSISTANT>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    integrator_id: u32,
    max_integrator_fee_b9: u32,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    registry.assert_integrator_id_is_valid(integrator_id);
    assert!(
        max_integrator_fee_b9 != 0 && max_integrator_fee_b9 <= 10_000_000,
        invalid_integrator_fee!(),
    );
    dynamic_field::add(
        &mut account.id,
        keys::integrator_config(integrator_id),
        IntegratorConfig { max_integrator_fee_b9 },
    )
}

public fun remove_integrator_config<T>(
    account: &mut Account<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry: &Registry,
    integrator_id: u32,
) {
    registry.assert_package_version();
    account.assert_authority_cap_is_valid(cap);
    let IntegratorConfig { max_integrator_fee_b9: _ } = dynamic_field::remove(
        &mut account.id,
        keys::integrator_config(integrator_id),
    );
}

fun revoke_assistant_account_cap_<T>(
    account: &mut Account<T>,
    assistant_cap_id: ID,
) {
    let idx = account.active_assistants.find_index!(|id| *id == assistant_cap_id);
    idx.do!(|i| { account.active_assistants.remove(i); });
}

/// A cap is valid if it was minted for this account and is either the admin cap or one of the
/// account's currently active assistant caps.
public(package) fun assert_authority_cap_is_valid<T, Role>(
    account: &Account<T>,
    cap: &AuthorityCap<ACCOUNT, Role>,
) {
    // The rebinding stands in for a macro parameter of the original source; keeping it (and a
    // name sorting before `cap`) preserves the compiled reference-release order.
    let acc = account;
    let role = type_name::with_defining_ids<Role>();
    let is_valid = cap.`for`() == acc.id.to_inner() && ({
        let actual = role;
        let expected = type_name::with_defining_ids<ADMIN>();
        actual == expected
    } || ({
        let actual = role;
        let expected = type_name::with_defining_ids<ASSISTANT>();
        actual == expected
    } && acc.active_assistants.contains(&object::id(cap))));
    assert!(is_valid, invalid_account_cap!())
}

public(package) fun assert_order_ticket_exists<T>(account: &Account<T>, ticket_id: ID) {
    assert!(account.has_order_ticket(ticket_id), order_invalid_account!())
}

public(package) fun validate_session_integrator_info<T>(
    account: &Account<T>,
    integrator_info: &IntegratorInfo,
): u32 {
    let max_integrator_fee = account
        .integrator_config(integrator_info.integrator_id)
        .max_integrator_fee_b9();
    assert!(integrator_info.integrator_fee <= max_integrator_fee, invalid_integrator_fee!());
    integrator_info.integrator_id
}
