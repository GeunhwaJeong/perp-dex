// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The perpetuals fixture with this package's witness authorized, a fee schedule and a staking
/// tier registry. The schedule's base rates are the fixture market's rates (taker 0.05%,
/// maker 0.02%), so a tier's rate is what the account pays.
#[test_only]
module perpetuals_fees::fees_test_support;

use haneul::test_scenario::{Self as ts, Scenario};
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::Account;
use perpetuals::clearing_house::{ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t, Fx};
use perpetuals::tusd::TUSD;
use perpetuals_fees::config::{Self, AdminCap as ScheduleCap, FeeSchedule};
use perpetuals_fees::extension::FEES;
use perpetuals_fees::fees;
use staking_tiers::registry::{Self as tiers, AdminCap as TierCap, TierRegistry};
use ifixed::ifixed;

const ONE: u256 = 1_000_000_000_000_000_000;
const HANEUL: u64 = 1_000_000_000;

public struct FeesFx {
    schedule: ID,
    tiers: ID,
    schedule_cap: ScheduleCap,
    tier_cap: TierCap,
}

public fun schedule_id(ffx: &FeesFx): ID { ffx.schedule }
public fun tiers_id(ffx: &FeesFx): ID { ffx.tiers }
public fun schedule_cap(ffx: &FeesFx): &ScheduleCap { &ffx.schedule_cap }
public fun tier_cap(ffx: &FeesFx): &TierCap { &ffx.tier_cap }
public fun haneul(): u64 { HANEUL }

/// Thousandths of a dollar to an ifixed value.
public fun musd(thousandths: u64): u256 { (thousandths as u256) * ONE / 1000 }

/// Millionths of a dollar to an ifixed value.
public fun uusd(millionths: u64): u256 { (millionths as u256) * ONE / 1_000_000 }

/// An ifixed fraction in percent.
public fun pct(percent: u64): u256 { (percent as u256) * ONE / 100 }

/// Basis points of notional as an ifixed rate: 5 bp is 0.05%.
public fun bps(basis_points: u64): u256 { (basis_points as u256) * ONE / 10_000 }

public fun neg(value: u256): u256 { ifixed::neg(value) }

/// Three volume tiers (0.05%/0.02% under $20k, 0.04%/0.015% under $100k, 0.03%/0.01% above),
/// three staking tiers (5% at 10, 10% at 100, 40% at 1,000 HANEUL) and two maker-share tiers
/// (a 0.001% rebate from half the market's maker volume and $5,000 of the maker's own, 0.002%
/// from 90% and $10,000).
public fun setup(): (Scenario, Fx, FeesFx) {
    let (mut sc, fx) = t::setup();
    sc.next_tx(fx.admin());
    let mut registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    registry.authorize_extension<FEES>(fx.perp_admin());
    ts::return_shared(registry);
    config::init_for_testing(sc.ctx());
    tiers::init_for_testing(sc.ctx());

    sc.next_tx(fx.admin());
    let mut schedule = sc.take_shared<FeeSchedule>();
    let mut tier_registry = sc.take_shared<TierRegistry>();
    let schedule_cap = sc.take_from_sender<ScheduleCap>();
    let tier_cap = sc.take_from_sender<TierCap>();
    schedule.set_schedule(
        &schedule_cap,
        t::taker_fee(),
        t::maker_fee(),
        vector[0, t::usd(20_000), t::usd(100_000)],
        vector[bps(5), bps(4), bps(3)],
        vector[bps(2), bps(2) * 3 / 4, bps(1)],
        vector[10 * HANEUL, 100 * HANEUL, 1_000 * HANEUL],
        vector[pct(5), pct(10), pct(40)],
        vector[pct(50), pct(90)],
        vector[t::usd(5_000), t::usd(10_000)],
        vector[neg(bps(1) / 10), neg(bps(1) / 5)],
        86_400_000,
        14,
    );
    tier_registry.set_thresholds(&tier_cap, vector[10 * HANEUL, 100 * HANEUL, 1_000 * HANEUL]);
    let ffx = FeesFx {
        schedule: object::id(&schedule),
        tiers: object::id(&tier_registry),
        schedule_cap,
        tier_cap,
    };
    ts::return_shared(schedule);
    ts::return_shared(tier_registry);
    (sc, fx, ffx)
}

public fun finish(sc: Scenario, fx: Fx, ffx: FeesFx) {
    let FeesFx { schedule: _, tiers: _, schedule_cap, tier_cap } = ffx;
    transfer::public_transfer(schedule_cap, @0x0);
    transfer::public_transfer(tier_cap, @0x0);
    t::finish(sc, fx);
}

/// Gives `owner` an active stake in the tier registry.
public fun stake(sc: &mut Scenario, fx: &Fx, ffx: &FeesFx, owner: address, amount: u64) {
    sc.next_tx(fx.admin());
    let mut tier_registry = sc.take_shared_by_id<TierRegistry>(ffx.tiers);
    tier_registry.set_active_stake_for_testing(owner, amount);
    ts::return_shared(tier_registry);
}

/// A trading session for account `who`, ended through `fees::end_session`, signed by the admin.
public macro fun fees_session(
    $sc: &mut Scenario,
    $fx: &Fx,
    $ffx: &FeesFx,
    $who: u64,
    $f: |&mut SessionHotPotato<TUSD>|,
): SessionSummary {
    let (sc, fx, ffx) = ($sc, $fx, $ffx);
    let sender = fx.admin();
    fees_session_as!(sc, fx, ffx, $who, sender, $f)
}

/// `fees_session` signed by `sender`.
public macro fun fees_session_as(
    $sc: &mut Scenario,
    $fx: &Fx,
    $ffx: &FeesFx,
    $who: u64,
    $sender: address,
    $f: |&mut SessionHotPotato<TUSD>|,
): SessionSummary {
    let (sc, fx, ffx) = ($sc, $fx, $ffx);
    sc.next_tx($sender);
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj($who));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_btc_id());
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_tusd_id());
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    let schedule = sc.take_shared_by_id<FeeSchedule>(ffx.schedule_id());
    let tier_registry = sc.take_shared_by_id<TierRegistry>(ffx.tiers_id());
    let cap = fx.cap($who);
    let mut hp = clearing_house.start_session(
        cap, &mut account, &pfs_btc, &pfs_tusd, option::none(), fx.clock(), sc.ctx(),
    );
    $f(&mut hp);
    let (clearing_house, summary) = fees::end_session(
        hp, cap, &mut account, &registry, &schedule, &tier_registry, false, false, fx.clock(), sc.ctx(),
    );
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    ts::return_shared(registry);
    ts::return_shared(schedule);
    ts::return_shared(tier_registry);
    summary
}

/// Caches account `who`'s multipliers on the market without trading, signed by the admin.
public fun refresh(sc: &mut Scenario, fx: &Fx, ffx: &FeesFx, who: u64) {
    refresh_as(sc, fx, ffx, who, fx.admin())
}

/// `refresh` signed by `sender`. The fixture keeps the account caps outside any address, so any
/// sender can present them.
public fun refresh_as(sc: &mut Scenario, fx: &Fx, ffx: &FeesFx, who: u64, sender: address) {
    sc.next_tx(sender);
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj(who));
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    let schedule = sc.take_shared_by_id<FeeSchedule>(ffx.schedule);
    let tier_registry = sc.take_shared_by_id<TierRegistry>(ffx.tiers);
    fees::refresh(
        &mut clearing_house, fx.cap(who), &mut account, &registry, &schedule, &tier_registry,
        fx.clock(), sc.ctx(),
    );
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(registry);
    ts::return_shared(schedule);
    ts::return_shared(tier_registry);
}

/// Registers `sender` as account `who`'s tier address.
public fun set_tier_address(sc: &mut Scenario, fx: &Fx, who: u64, sender: address) {
    sc.next_tx(sender);
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj(who));
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    fees::set_tier_address(&mut account, fx.cap(who), &registry, sc.ctx());
    ts::return_shared(account);
    ts::return_shared(registry);
}

/// Clears account `who`'s tier address.
public fun clear_tier_address(sc: &mut Scenario, fx: &Fx, who: u64) {
    sc.next_tx(fx.admin());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj(who));
    let registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    fees::clear_tier_address(&mut account, fx.cap(who), &registry);
    ts::return_shared(account);
    ts::return_shared(registry);
}

/// The address whose stake would price account `who` when `sender` signs.
public fun tier_address_of(sc: &mut Scenario, fx: &Fx, who: u64, sender: address): address {
    sc.next_tx(fx.admin());
    let account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj(who));
    let tier_address = fees::tier_address(&account, sender);
    ts::return_shared(account);
    tier_address
}

/// The multipliers the market holds for account `who` right now.
public fun multipliers_on_market(sc: &mut Scenario, fx: &Fx, who: u64): (u256, u256) {
    sc.next_tx(fx.admin());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let (taker, maker) = clearing_house.fee_multiplier(fx.account_id(who), fx.clock().timestamp_ms());
    ts::return_shared(clearing_house);
    (taker, maker)
}

/// Account `who`'s recorded window volume at the current epoch.
public fun volume_of(sc: &mut Scenario, fx: &Fx, who: u64): u256 {
    sc.next_tx(fx.admin());
    let account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj(who));
    let volume = fees::volume(&account, sc.ctx().epoch());
    ts::return_shared(account);
    volume
}

/// Account `who`'s position collateral.
public fun collateral_of(sc: &mut Scenario, fx: &Fx, who: u64): u256 {
    sc.next_tx(fx.admin());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let (collateral, _, _, _, _, _) = t::position_of(&clearing_house, fx.account_id(who));
    ts::return_shared(clearing_house);
    collateral
}

/// The market's accrued fees.
public fun fees_accrued(sc: &mut Scenario, fx: &Fx): u256 {
    sc.next_tx(fx.admin());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let fees = clearing_house.market_state().fees_accrued();
    ts::return_shared(clearing_house);
    fees
}
