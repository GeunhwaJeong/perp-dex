// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Fee tiers for perpetuals accounts. Ending a session through this module records the
/// session's taker notional in the account's volume window and caches the resulting fee
/// multipliers on the market for the account's next sessions. `refresh` does the caching alone,
/// for a market the account has not traded on since its tier changed.
///
/// The staking tier is read from the `staking_tiers` registry for the transaction sender, so
/// the discount follows the address that signs, not the account object.
///
/// Sessions ended directly through the perpetuals core still work; they simply record no volume.
module perpetuals_fees::fees;

use authority_cap::authority::AuthorityCap;
use haneul::clock::Clock;
use haneul::event;
use perpetuals::account::Account;
use perpetuals::authority::ACCOUNT;
use perpetuals::clearing_house::{ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals_fees::config::FeeSchedule;
use perpetuals_fees::extension::{Self, FEES};
use perpetuals_fees::volume::{Self, VolumeWindow};
use staking_tiers::registry::TierRegistry;
use ifixed::ifixed;

// === Types ===

public struct VolumeKey has copy, drop, store {}

// === Events ===

public struct TierApplied has copy, drop {
    ch_id: ID,
    account_id: u64,
    sender: address,
    volume: u256,
    stake: u64,
    taker_multiplier: u256,
    maker_multiplier: u256,
    expires_ms: u64,
}

// === Entry points ===

/// Ends a session as the core does, then credits its taker notional and refreshes the fee
/// multipliers on this market.
public fun end_session<T, ADMIN_OR_ASSISTANT>(
    hot_potato: SessionHotPotato<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    registry: &Registry,
    schedule: &FeeSchedule,
    tiers: &TierRegistry,
    allocate_missing_margin: bool,
    deallocate_free_collateral: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<T>, SessionSummary) {
    account.assert_authority_cap_is_valid(cap);
    let (mut clearing_house, summary) = hot_potato.end_session_as_extension(
        &extension::witness(),
        registry,
        account,
        allocate_missing_margin,
        deallocate_free_collateral,
        false,
    );
    let (_, quote_ask) = summary.filled_base_and_quote(true);
    let (_, quote_bid) = summary.filled_base_and_quote(false);
    let epoch = ctx.epoch();
    let volume = record_volume(account, registry, schedule, epoch, ifixed::add(quote_ask, quote_bid));
    apply_multipliers(&mut clearing_house, account, registry, schedule, tiers, volume, clock, ctx);
    (clearing_house, summary)
}

/// Caches the account's current multipliers on `clearing_house` without trading.
public fun refresh<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    registry: &Registry,
    schedule: &FeeSchedule,
    tiers: &TierRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    account.assert_authority_cap_is_valid(cap);
    let volume = record_volume(account, registry, schedule, ctx.epoch(), 0);
    apply_multipliers(clearing_house, account, registry, schedule, tiers, volume, clock, ctx);
}

// === Views ===

/// Taker volume the account has recorded over the schedule's window ending at `epoch`.
public fun volume<T>(account: &Account<T>, epoch: u64): u256 {
    if (!account.has_extension_field<T, FEES, VolumeKey>(VolumeKey {})) return 0;
    let window: &VolumeWindow = account.borrow_extension_field<T, FEES, VolumeKey, VolumeWindow>(VolumeKey {});
    window.total(epoch)
}

/// The multipliers `sender` would get on `account` at `epoch`.
public fun multipliers_for<T>(
    account: &Account<T>,
    schedule: &FeeSchedule,
    tiers: &TierRegistry,
    sender: address,
    epoch: u64,
): (u256, u256) {
    schedule.multipliers(volume(account, epoch), tiers.active_stake(sender))
}

// === Internal ===

/// Adds `notional` to the account's window for `epoch` and returns the window total. A window
/// whose length no longer matches the schedule is started over.
fun record_volume<T>(
    account: &mut Account<T>,
    registry: &Registry,
    schedule: &FeeSchedule,
    epoch: u64,
    notional: u256,
): u256 {
    let witness = extension::witness();
    let length = schedule.window_epochs();
    if (account.has_extension_field<T, FEES, VolumeKey>(VolumeKey {})) {
        let stale = {
            let window: &VolumeWindow =
                account.borrow_extension_field<T, FEES, VolumeKey, VolumeWindow>(VolumeKey {});
            window.length() != length
        };
        if (stale) {
            let window: VolumeWindow = account.remove_extension_field_as_extension<T, FEES, VolumeKey, VolumeWindow>(
                &witness, registry, VolumeKey {},
            );
            window.destroy();
        };
    };
    if (!account.has_extension_field<T, FEES, VolumeKey>(VolumeKey {})) {
        account.add_extension_field_as_extension<T, FEES, VolumeKey, VolumeWindow>(
            &witness, registry, VolumeKey {}, volume::new(length),
        );
    };
    let window: &mut VolumeWindow = account.borrow_mut_extension_field_as_extension<T, FEES, VolumeKey, VolumeWindow>(
        &witness, registry, VolumeKey {},
    );
    if (notional != 0) window.record(epoch, notional);
    window.total(epoch)
}

fun apply_multipliers<T>(
    clearing_house: &mut ClearingHouse<T>,
    account: &Account<T>,
    registry: &Registry,
    schedule: &FeeSchedule,
    tiers: &TierRegistry,
    volume: u256,
    clock: &Clock,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    let stake = tiers.active_stake(sender);
    let (taker_multiplier, maker_multiplier) = schedule.multipliers(volume, stake);
    let expires_ms = clock.timestamp_ms() + schedule.multiplier_ttl_ms();
    let account_id = account.account_id();
    clearing_house.set_fee_multiplier_as_extension(
        &extension::witness(),
        registry,
        account_id,
        taker_multiplier,
        maker_multiplier,
        expires_ms,
    );
    event::emit(TierApplied {
        ch_id: object::id(clearing_house),
        account_id,
        sender,
        volume,
        stake,
        taker_multiplier,
        maker_multiplier,
        expires_ms,
    });
}
