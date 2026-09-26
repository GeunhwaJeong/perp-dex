// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Fee tiers for perpetuals accounts. Ending a session through this module records the
/// session's taker notional in the account's volume window, credits every maker it filled with
/// maker volume on the market, and caches the resulting fee multipliers on the market for the
/// account's next sessions. `refresh` does the caching alone, for a market the account has not
/// traded on since its tier changed.
///
/// Volume lives in two places. The account's own window (an extension field on the account)
/// is the sum of its taker volume everywhere and its maker volume on every market it has since
/// touched; it decides the volume tier. Maker volume is first credited on the market, in a
/// staging window per maker, because the maker's account is not in the taker's transaction;
/// the maker's next session or refresh on that market sweeps it into the account window. A
/// second, unswept copy per maker and one for the whole market give the maker's share of the
/// market's maker volume, which decides the rebate tier.
///
/// The staking tier is read from the `staking_tiers` registry for the transaction sender, so
/// the discount follows the address that signs, not the account object.
///
/// Sessions ended directly through the perpetuals core still work; they simply record no volume.
module perpetuals_fees::fees;

use authority_cap::authority::AuthorityCap;
use haneul::clock::Clock;
use haneul::event;
use ifixed::ifixed;
use perpetuals::account::Account;
use perpetuals::authority::ACCOUNT;
use perpetuals::clearing_house::{ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals_fees::config::FeeSchedule;
use perpetuals_fees::extension::{Self, FEES};
use perpetuals_fees::volume::{Self, VolumeWindow};
use staking_tiers::registry::TierRegistry;

// === Types ===

/// The account's window: taker volume plus swept maker volume.
public struct VolumeKey has copy, drop, store {}

/// Maker volume credited on a market and not yet swept into the maker's account window.
public struct UnsweptMakerVolumeKey has copy, drop, store { account_id: u64 }

/// A maker's volume on a market over the window, for its share.
public struct MakerVolumeKey has copy, drop, store { account_id: u64 }

/// A market's maker volume over the window.
public struct MarketMakerVolumeKey has copy, drop, store {}

// === Events ===

public struct TierApplied has copy, drop {
    ch_id: ID,
    account_id: u64,
    sender: address,
    volume: u256,
    maker_volume: u256,
    stake: u64,
    maker_share: u256,
    taker_multiplier: u256,
    maker_multiplier: u256,
    expires_ms: u64,
}

// === Entry points ===

/// Ends a session as the core does, then credits its taker notional to the account, its maker
/// fills to the makers, and refreshes the account's fee multipliers on this market.
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
    let epoch = ctx.epoch();
    credit_makers(&mut clearing_house, registry, schedule, epoch, &summary);
    let (_, quote_ask) = summary.filled_base_and_quote(true);
    let (_, quote_bid) = summary.filled_base_and_quote(false);
    let volume = update_account_volume(&mut clearing_house, account, registry, schedule, epoch, ifixed::add(quote_ask, quote_bid));
    apply_multipliers(&mut clearing_house, account, registry, schedule, tiers, volume, clock, ctx);
    (clearing_house, summary)
}

/// Sweeps the account's maker volume on `clearing_house` and caches its current multipliers
/// there without trading.
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
    let volume = update_account_volume(clearing_house, account, registry, schedule, ctx.epoch(), 0);
    apply_multipliers(clearing_house, account, registry, schedule, tiers, volume, clock, ctx);
}

// === Views ===

/// Volume the account has in its window at `epoch`: taker volume plus swept maker volume.
public fun volume<T>(account: &Account<T>, epoch: u64): u256 {
    if (!account.has_extension_field<T, FEES, VolumeKey>(VolumeKey {})) return 0;
    let window: &VolumeWindow = account.borrow_extension_field<T, FEES, VolumeKey, VolumeWindow>(VolumeKey {});
    window.total(epoch)
}

/// Maker volume credited to `account_id` on this market but not yet swept.
public fun unswept_maker_volume<T>(clearing_house: &ClearingHouse<T>, account_id: u64, epoch: u64): u256 {
    window_total<T, UnsweptMakerVolumeKey>(clearing_house, UnsweptMakerVolumeKey { account_id }, epoch)
}

/// `account_id`'s maker volume on this market over the window.
public fun maker_volume<T>(clearing_house: &ClearingHouse<T>, account_id: u64, epoch: u64): u256 {
    window_total<T, MakerVolumeKey>(clearing_house, MakerVolumeKey { account_id }, epoch)
}

/// The market's maker volume over the window.
public fun market_maker_volume<T>(clearing_house: &ClearingHouse<T>, epoch: u64): u256 {
    window_total<T, MarketMakerVolumeKey>(clearing_house, MarketMakerVolumeKey {}, epoch)
}

/// `account_id`'s share of the market's maker volume, an ifixed fraction.
public fun maker_share<T>(clearing_house: &ClearingHouse<T>, account_id: u64, epoch: u64): u256 {
    let market = market_maker_volume(clearing_house, epoch);
    if (market == 0) return 0;
    ifixed::div_toward_zero(maker_volume(clearing_house, account_id, epoch), market)
}

/// The multipliers a session signed by `sender` would get on `account` for `clearing_house` at
/// `epoch`, counting maker volume not yet swept.
public fun multipliers_for<T>(
    clearing_house: &ClearingHouse<T>,
    account: &Account<T>,
    schedule: &FeeSchedule,
    tiers: &TierRegistry,
    sender: address,
    epoch: u64,
): (u256, u256) {
    let account_id = account.account_id();
    let volume = ifixed::add(volume(account, epoch), unswept_maker_volume(clearing_house, account_id, epoch));
    schedule.multipliers(
        volume,
        tiers.active_stake(sender),
        maker_share(clearing_house, account_id, epoch),
        maker_volume(clearing_house, account_id, epoch),
    )
}

// === Internal ===

/// Credits each maker fill of `summary` to the maker's unswept and market-share windows and to
/// the market's total.
fun credit_makers<T>(
    clearing_house: &mut ClearingHouse<T>,
    registry: &Registry,
    schedule: &FeeSchedule,
    epoch: u64,
    summary: &SessionSummary,
) {
    let fills = summary.maker_fills();
    if (fills.is_empty()) return;
    let length = schedule.window_epochs();
    let mut total = 0;
    fills.do_ref!(|fill| {
        let (account_id, quote) = (fill.maker_fill_account_id(), fill.maker_fill_quote());
        total = ifixed::add(total, quote);
        market_window_mut<T, UnsweptMakerVolumeKey>(clearing_house, registry, UnsweptMakerVolumeKey { account_id }, length)
            .record(epoch, quote);
        market_window_mut<T, MakerVolumeKey>(clearing_house, registry, MakerVolumeKey { account_id }, length)
            .record(epoch, quote);
    });
    market_window_mut<T, MarketMakerVolumeKey>(clearing_house, registry, MarketMakerVolumeKey {}, length)
        .record(epoch, total);
}

/// Adds `notional` of taker volume and the account's unswept maker volume on this market to
/// the account window, and returns the window total. A window whose length no longer matches
/// the schedule is started over.
fun update_account_volume<T>(
    clearing_house: &mut ClearingHouse<T>,
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
    let unswept_key = UnsweptMakerVolumeKey { account_id: account.account_id() };
    let unswept = if (clearing_house.has_extension_field<T, FEES, UnsweptMakerVolumeKey>(unswept_key)) {
        option::some(clearing_house.remove_extension_field_as_extension<T, FEES, UnsweptMakerVolumeKey, VolumeWindow>(
            &witness, registry, unswept_key,
        ))
    } else {
        option::none()
    };
    let window: &mut VolumeWindow = account.borrow_mut_extension_field_as_extension<T, FEES, VolumeKey, VolumeWindow>(
        &witness, registry, VolumeKey {},
    );
    if (notional != 0) window.record(epoch, notional);
    if (unswept.is_some()) {
        let staged = unswept.destroy_some();
        window.merge(&staged, epoch);
        staged.destroy();
    } else {
        unswept.destroy_none();
    };
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
    let account_id = account.account_id();
    let epoch = ctx.epoch();
    let maker_share = maker_share(clearing_house, account_id, epoch);
    let maker_volume = maker_volume(clearing_house, account_id, epoch);
    let (taker_multiplier, maker_multiplier) =
        schedule.multipliers(volume, stake, maker_share, maker_volume);
    let expires_ms = clock.timestamp_ms() + schedule.multiplier_ttl_ms();
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
        maker_volume,
        stake,
        maker_share,
        taker_multiplier,
        maker_multiplier,
        expires_ms,
    });
}

/// The window under `key` on the market, created with `length` buckets when missing or
/// started over when its length no longer matches the schedule.
fun market_window_mut<T, K: copy + drop + store>(
    clearing_house: &mut ClearingHouse<T>,
    registry: &Registry,
    key: K,
    length: u64,
): &mut VolumeWindow {
    let witness = extension::witness();
    if (clearing_house.has_extension_field<T, FEES, K>(key)) {
        let stale = {
            let window: &VolumeWindow = clearing_house.borrow_extension_field<T, FEES, K, VolumeWindow>(key);
            window.length() != length
        };
        if (stale) {
            let window: VolumeWindow =
                clearing_house.remove_extension_field_as_extension<T, FEES, K, VolumeWindow>(&witness, registry, key);
            window.destroy();
        };
    };
    if (!clearing_house.has_extension_field<T, FEES, K>(key)) {
        clearing_house.add_extension_field_as_extension<T, FEES, K, VolumeWindow>(&witness, registry, key, volume::new(length));
    };
    clearing_house.borrow_mut_extension_field_as_extension<T, FEES, K, VolumeWindow>(&witness, registry, key)
}

fun window_total<T, K: copy + drop + store>(clearing_house: &ClearingHouse<T>, key: K, epoch: u64): u256 {
    if (!clearing_house.has_extension_field<T, FEES, K>(key)) return 0;
    let window: &VolumeWindow = clearing_house.borrow_extension_field<T, FEES, K, VolumeWindow>(key);
    window.total(epoch)
}
