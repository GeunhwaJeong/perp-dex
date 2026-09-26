// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Staking tiers: a shared registry that holds `StakedHaneul` objects on behalf of their
/// owners and grades each address by the principal it keeps deposited.
///
/// Native staking keeps earning validator rewards while an object sits here, because rewards
/// are computed from the pool exchange rate at withdrawal time. What the registry adds is a
/// commitment: a deposit counts toward the owner's tier immediately, but leaving takes a
/// withdrawal request and a delay (`withdraw_delay_ms`), so a tier cannot be rented for one
/// transaction. Other packages read `active_stake` or `tier` to price their services.
module staking_tiers::registry;

use haneul::clock::Clock;
use haneul::dynamic_object_field as dof;
use haneul::event;
use haneul::table::{Self, Table};
use haneul_system::staking_pool::StakedHaneul;

// === Errors ===

const ENotDepositOwner: u64 = 1;
const EUnknownDeposit: u64 = 2;
const EWithdrawalNotRequested: u64 = 3;
const EWithdrawalAlreadyRequested: u64 = 4;
const EWithdrawalDelayNotElapsed: u64 = 5;
const EThresholdsNotAscending: u64 = 6;
const EWrongVersion: u64 = 7;

// === Constants ===

const VERSION: u64 = 1;
const MS_PER_DAY: u64 = 86_400_000;
const DEFAULT_WITHDRAW_DELAY_MS: u64 = 7 * MS_PER_DAY;

// === Types ===

public struct TierRegistry has key {
    id: UID,
    version: u64,
    /// How long a withdrawal request waits before the object can leave.
    withdraw_delay_ms: u64,
    /// Ascending principal thresholds; an address is in tier `n` when its active stake reaches
    /// the `n`-th threshold (tier 0 below the first).
    thresholds: vector<u64>,
    /// Per-owner totals.
    entries: Table<address, Entry>,
    /// Per-deposit bookkeeping; the `StakedHaneul` itself is a dynamic object field keyed by
    /// its ID.
    deposits: Table<ID, Deposit>,
}

public struct Entry has store {
    active: u64,
    pending: u64,
}

public struct Deposit has store {
    owner: address,
    principal: u64,
    /// Set by a withdrawal request; the object can leave once the clock passes it.
    unlock_ms: Option<u64>,
}

public struct AdminCap has key, store { id: UID }

public struct DepositKey has copy, drop, store { stake_id: ID }

// === Events ===

public struct Deposited has copy, drop {
    owner: address,
    stake_id: ID,
    principal: u64,
    active_after: u64,
}

public struct WithdrawalRequested has copy, drop {
    owner: address,
    stake_id: ID,
    principal: u64,
    unlock_ms: u64,
    active_after: u64,
}

public struct WithdrawalCanceled has copy, drop {
    owner: address,
    stake_id: ID,
    principal: u64,
    active_after: u64,
}

public struct Withdrawn has copy, drop {
    owner: address,
    stake_id: ID,
    principal: u64,
}

public struct ThresholdsUpdated has copy, drop { thresholds: vector<u64> }

public struct WithdrawDelayUpdated has copy, drop { withdraw_delay_ms: u64 }

// === Init ===

fun init(ctx: &mut TxContext) {
    let registry = TierRegistry {
        id: object::new(ctx),
        version: VERSION,
        withdraw_delay_ms: DEFAULT_WITHDRAW_DELAY_MS,
        thresholds: vector[],
        entries: table::new(ctx),
        deposits: table::new(ctx),
    };
    transfer::share_object(registry);
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === User functions ===

/// Deposits a `StakedHaneul`; its principal counts toward the sender's tier at once.
public fun deposit(registry: &mut TierRegistry, stake: StakedHaneul, ctx: &TxContext) {
    registry.assert_version();
    let owner = ctx.sender();
    let stake_id = object::id(&stake);
    let principal = stake.staked_haneul_amount();
    if (!registry.entries.contains(owner)) {
        registry.entries.add(owner, Entry { active: 0, pending: 0 });
    };
    let entry = &mut registry.entries[owner];
    entry.active = entry.active + principal;
    let active_after = entry.active;
    registry.deposits.add(stake_id, Deposit { owner, principal, unlock_ms: option::none() });
    dof::add(&mut registry.id, DepositKey { stake_id }, stake);
    event::emit(Deposited { owner, stake_id, principal, active_after });
}

/// Starts the withdrawal clock for one deposit. The principal leaves the sender's active
/// stake now, so the tier drops before the object does.
public fun request_withdrawal(
    registry: &mut TierRegistry,
    stake_id: ID,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.assert_version();
    let owner = ctx.sender();
    let delay = registry.withdraw_delay_ms;
    let deposit = registry.borrow_deposit_mut(stake_id, owner);
    assert!(deposit.unlock_ms.is_none(), EWithdrawalAlreadyRequested);
    let unlock_ms = clock.timestamp_ms() + delay;
    deposit.unlock_ms = option::some(unlock_ms);
    let principal = deposit.principal;
    let entry = &mut registry.entries[owner];
    entry.active = entry.active - principal;
    entry.pending = entry.pending + principal;
    event::emit(WithdrawalRequested {
        owner,
        stake_id,
        principal,
        unlock_ms,
        active_after: entry.active,
    });
}

/// Cancels a pending withdrawal; the principal counts again from now.
public fun cancel_withdrawal(registry: &mut TierRegistry, stake_id: ID, ctx: &TxContext) {
    registry.assert_version();
    let owner = ctx.sender();
    let deposit = registry.borrow_deposit_mut(stake_id, owner);
    assert!(deposit.unlock_ms.is_some(), EWithdrawalNotRequested);
    deposit.unlock_ms = option::none();
    let principal = deposit.principal;
    let entry = &mut registry.entries[owner];
    entry.pending = entry.pending - principal;
    entry.active = entry.active + principal;
    event::emit(WithdrawalCanceled { owner, stake_id, principal, active_after: entry.active });
}

/// Returns the object once its withdrawal delay has elapsed.
public fun withdraw(
    registry: &mut TierRegistry,
    stake_id: ID,
    clock: &Clock,
    ctx: &TxContext,
): StakedHaneul {
    registry.assert_version();
    let owner = ctx.sender();
    assert!(registry.deposits.contains(stake_id), EUnknownDeposit);
    let Deposit { owner: deposit_owner, principal, unlock_ms } = registry.deposits.remove(stake_id);
    assert!(deposit_owner == owner, ENotDepositOwner);
    assert!(unlock_ms.is_some(), EWithdrawalNotRequested);
    assert!(clock.timestamp_ms() >= unlock_ms.destroy_some(), EWithdrawalDelayNotElapsed);
    let entry = &mut registry.entries[owner];
    entry.pending = entry.pending - principal;
    event::emit(Withdrawn { owner, stake_id, principal });
    dof::remove(&mut registry.id, DepositKey { stake_id })
}

entry fun withdraw_and_transfer(
    registry: &mut TierRegistry,
    stake_id: ID,
    clock: &Clock,
    ctx: &TxContext,
) {
    let stake = registry.withdraw(stake_id, clock, ctx);
    transfer::public_transfer(stake, ctx.sender())
}

// === Views ===

/// Principal that currently counts toward `owner`'s tier.
public fun active_stake(registry: &TierRegistry, owner: address): u64 {
    if (!registry.entries.contains(owner)) return 0;
    registry.entries[owner].active
}

/// Principal waiting out a withdrawal delay.
public fun pending_stake(registry: &TierRegistry, owner: address): u64 {
    if (!registry.entries.contains(owner)) return 0;
    registry.entries[owner].pending
}

/// Number of thresholds `owner`'s active stake reaches.
public fun tier(registry: &TierRegistry, owner: address): u64 {
    registry.tier_for_stake(registry.active_stake(owner))
}

public fun tier_for_stake(registry: &TierRegistry, stake: u64): u64 {
    let mut tier = 0;
    registry.thresholds.do_ref!(|threshold| if (stake >= *threshold) tier = tier + 1);
    tier
}

public fun thresholds(registry: &TierRegistry): &vector<u64> { &registry.thresholds }

public fun withdraw_delay_ms(registry: &TierRegistry): u64 { registry.withdraw_delay_ms }

public fun deposit_owner(registry: &TierRegistry, stake_id: ID): address {
    registry.deposits[stake_id].owner
}

public fun deposit_principal(registry: &TierRegistry, stake_id: ID): u64 {
    registry.deposits[stake_id].principal
}

public fun deposit_unlock_ms(registry: &TierRegistry, stake_id: ID): Option<u64> {
    registry.deposits[stake_id].unlock_ms
}

public fun has_deposit(registry: &TierRegistry, stake_id: ID): bool {
    registry.deposits.contains(stake_id)
}

// === Admin ===

public fun set_thresholds(registry: &mut TierRegistry, _: &AdminCap, thresholds: vector<u64>) {
    registry.assert_version();
    let mut i = 1;
    while (i < thresholds.length()) {
        assert!(thresholds[i - 1] < thresholds[i], EThresholdsNotAscending);
        i = i + 1;
    };
    registry.thresholds = thresholds;
    event::emit(ThresholdsUpdated { thresholds });
}

public fun set_withdraw_delay_ms(registry: &mut TierRegistry, _: &AdminCap, withdraw_delay_ms: u64) {
    registry.assert_version();
    registry.withdraw_delay_ms = withdraw_delay_ms;
    event::emit(WithdrawDelayUpdated { withdraw_delay_ms });
}

/// Bumps the stored version after a package upgrade that changes `VERSION`.
entry fun migrate(registry: &mut TierRegistry, _: &AdminCap) {
    assert!(registry.version < VERSION, EWrongVersion);
    registry.version = VERSION;
}

// === Internal ===

fun assert_version(registry: &TierRegistry) {
    assert!(registry.version == VERSION, EWrongVersion)
}

fun borrow_deposit_mut(registry: &mut TierRegistry, stake_id: ID, owner: address): &mut Deposit {
    assert!(registry.deposits.contains(stake_id), EUnknownDeposit);
    let deposit = &mut registry.deposits[stake_id];
    assert!(deposit.owner == owner, ENotDepositOwner);
    deposit
}

// === Test helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// Sets an address's active stake without objects, for other packages' tests.
#[test_only]
public fun set_active_stake_for_testing(registry: &mut TierRegistry, owner: address, active: u64) {
    if (!registry.entries.contains(owner)) {
        registry.entries.add(owner, Entry { active: 0, pending: 0 });
    };
    registry.entries[owner].active = active;
}
