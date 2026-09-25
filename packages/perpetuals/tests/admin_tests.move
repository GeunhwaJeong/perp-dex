// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Market administration on the `test_support` fixture: pause modes, market close and
/// settlement, fee and insurance fund withdrawals, margin ratio proposals and freezing.
#[test_only]
module perpetuals::admin_tests;

use authority_cap::authority::AuthorityCap;
use haneul::coin;
use haneul::test_scenario::{Self as ts, Scenario};
use perpetuals::authority::{FREEZE_GUARDIAN, PACKAGE, PAUSE_GUARDIAN, TREASURY, VENDOR};
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t, VK, session, with_ch, with_account, with_market};
use perpetuals::tusd::TUSD;

const ASK: bool = true;
const BID: bool = false;
const MAX_U64: u64 = 0xffff_ffff_ffff_ffff;

fun base(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }
fun ask_id(dollars: u64, counter: u64): u128 { ((t::px(dollars) as u128) << 64) | (counter as u128) }

/// Maker rests 2 BTC at 100,000 and the taker buys 1.9 of it.
fun open_positions(sc: &mut Scenario, fx: &t::Fx) {
    session!(sc, fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(2_000), t::px(100_000), 0, option::none(), false, option::none());
    });
    session!(sc, fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(1_900), false);
    });
}

fun pause_cap(sc: &mut Scenario, fx: &t::Fx): AuthorityCap<VENDOR<VK>, PAUSE_GUARDIAN> {
    sc.next_tx(t::admin(fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let cap = registry.create_vendor_pause_guardian_cap<VK>(t::perp_vk(fx), sc.ctx());
    ts::return_shared(registry);
    cap
}

fun treasury_cap(sc: &mut Scenario, fx: &t::Fx): AuthorityCap<VENDOR<VK>, TREASURY> {
    sc.next_tx(t::admin(fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let cap = registry.create_vendor_treasury_cap<VK>(t::perp_vk(fx), sc.ctx());
    ts::return_shared(registry);
    cap
}

fun freeze_cap(sc: &mut Scenario, fx: &t::Fx): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    sc.next_tx(t::admin(fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let cap = registry.create_package_freeze_guardian_cap(t::perp_admin(fx), sc.ctx());
    ts::return_shared(registry);
    cap
}

// === Pausing ===

#[test, expected_failure(abort_code = 32, location = perpetuals::clearing_house)]
fun a_paused_market_refuses_sessions() {
    let (mut sc, fx) = t::setup();
    let cap = pause_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.pause_market(&cap, registry, 1);
        assert!(ch.is_market_paused() && ch.market_pause_mode() == 1);
    });
    transfer::public_transfer(cap, @0x0);
    t::ladder(&mut sc, &fx, 100_000);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 32, location = perpetuals::clearing_house)]
fun a_fully_paused_market_refuses_cancels() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let cap = pause_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, account, _btc, _tusd, registry| {
        ch.pause_market(&cap, registry, 1);
        ch.cancel_orders(t::cap(&fx, t::maker()), account, vector[ask_id(100_000, 1)]);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test]
fun cancel_only_mode_still_allows_cancels() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let cap = pause_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, account, _btc, _tusd, registry| {
        ch.pause_market(&cap, registry, 2);
        assert!(ch.is_market_cancel_only());
        ch.cancel_orders(t::cap(&fx, t::maker()), account, vector[ask_id(100_000, 1)]);
        assert!(ch.best_price_u64(ASK) == option::some(t::px(100_100)));
        // The vendor resumes; trading works again.
        ch.resume_market(t::perp_vk(&fx), registry);
        assert!(!ch.is_market_paused());
    });
    transfer::public_transfer(cap, @0x0);
    let summary = session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(100), false);
    });
    assert!(summary.base_filled_bid() == base(100));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 53, location = perpetuals::clearing_house)]
fun pause_mode_must_be_one_or_two() {
    let (mut sc, fx) = t::setup();
    let cap = pause_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.pause_market(&cap, registry, 3);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

// === Close and settlement ===

#[test]
fun a_closed_market_settles_every_position() {
    let (mut sc, fx) = t::setup();
    open_positions(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.close_market(t::perp_vk(&fx), registry, t::clock(&fx));
        assert!(ch.is_market_paused());
        let (enabled, _, _) = ch.settlement_valuation_prices();
        assert!(!enabled);
        ch.set_settlement_prices(t::perp_vk(&fx), registry, t::usd(95_000), t::one());
        ch.enable_settlement(t::perp_vk(&fx), registry);
        let (enabled, base_price, collateral_price) = ch.settlement_valuation_prices();
        assert!(enabled && base_price == t::usd(95_000) && collateral_price == t::one());
    });
    // The taker's long closes at 95,000: 19,905 - 9,500 goes back to the account.
    with_market!(&mut sc, &fx, t::taker(), |ch, account, _btc, _tusd, _registry| {
        ch.close_position_at_settlement_prices(account, &vector[]);
        assert!(account.collateral_balance() == (80_000 + 10_405) * t::tusd_unit());
    });
    // The maker's resting ask must be canceled on the way; its short gains 9,500.
    with_market!(&mut sc, &fx, t::maker(), |ch, account, _btc, _tusd, _registry| {
        ch.close_position_at_settlement_prices(account, &vector[ask_id(100_000, 1)]);
        assert!(account.collateral_balance() == (500_000 + 500_000 - 38 + 9_500) * t::tusd_unit());
    });
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, asks, _, pending) = t::position_of(ch, t::account_id(&fx, t::maker()));
        assert!(base == 0 && asks == 0 && pending == 0);
        assert!(ch.market_state().open_interest() == 0);
        // Only the liquidator's untouched 100,000 and the 133 of fees remain in the vault.
        let (vault, _) = ch.collateral_and_insurance_fund_balances();
        assert!(vault == (100_000 + 133) * t::tusd_unit());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 36, location = perpetuals::clearing_house)]
fun settlement_needs_enabled_prices() {
    let (mut sc, fx) = t::setup();
    open_positions(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::taker(), |ch, account, _btc, _tusd, registry| {
        ch.close_market(t::perp_vk(&fx), registry, t::clock(&fx));
        ch.set_settlement_prices(t::perp_vk(&fx), registry, t::usd(95_000), t::one());
        ch.close_position_at_settlement_prices(account, &vector[]);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 34, location = perpetuals::clearing_house)]
fun settlement_prices_need_a_closed_market() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_settlement_prices(t::perp_vk(&fx), registry, t::usd(95_000), t::one());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 35, location = perpetuals::clearing_house)]
fun a_closed_market_cannot_be_resumed() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.close_market(t::perp_vk(&fx), registry, t::clock(&fx));
        ch.resume_market(t::perp_vk(&fx), registry);
    });
    t::finish(sc, fx);
}

// === Treasury ===

#[test]
fun fees_are_withdrawn_in_whole_units() {
    let (mut sc, fx) = t::setup();
    open_positions(&mut sc, &fx);
    let cap = treasury_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        // 95 of taker fee and 38 of maker fee.
        let fees = ch.withdraw_fees(&cap, registry, sc.ctx());
        assert!(fees.value() == 133 * t::tusd_unit());
        assert!(ch.market_state().fees_accrued() == 0);
        let (vault, _) = ch.collateral_and_insurance_fund_balances();
        assert!(vault == (620_000 - 133) * t::tusd_unit());
        // A second withdrawal is empty.
        let none = ch.withdraw_fees(&cap, registry, sc.ctx());
        assert!(none.value() == 0);
        coin::burn_for_testing(fees);
        coin::burn_for_testing(none);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test]
fun insurance_withdrawals_keep_the_open_interest_reserve() {
    let (mut sc, fx) = t::setup();
    open_positions(&mut sc, &fx);
    let cap = treasury_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        ch.donate_to_insurance_fund(coin::mint_for_testing<TUSD>(30_000 * t::tusd_unit(), sc.ctx()), sc.ctx());
        // 5% of the 190,000 of open interest notional, 9,500, must stay.
        let out = ch.withdraw_insurance_fund(&cap, registry, btc, tusd, t::clock(&fx), 20_000 * t::tusd_unit(), sc.ctx());
        assert!(out.value() == 20_000 * t::tusd_unit());
        let (_, insurance) = ch.collateral_and_insurance_fund_balances();
        assert!(insurance == 10_000 * t::tusd_unit());
        coin::burn_for_testing(out);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 29, location = perpetuals::clearing_house)]
fun insurance_withdrawals_beyond_the_surplus_abort() {
    let (mut sc, fx) = t::setup();
    open_positions(&mut sc, &fx);
    let cap = treasury_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, tusd, registry| {
        ch.donate_to_insurance_fund(coin::mint_for_testing<TUSD>(30_000 * t::tusd_unit(), sc.ctx()), sc.ctx());
        let out = ch.withdraw_insurance_fund(&cap, registry, btc, tusd, t::clock(&fx), 21_000 * t::tusd_unit(), sc.ctx());
        coin::burn_for_testing(out);
    });
    transfer::public_transfer(cap, @0x0);
    t::finish(sc, fx);
}

// === Margin ratio proposals ===

#[test]
fun margin_ratios_change_through_a_delayed_proposal() {
    let (mut sc, mut fx) = t::setup();
    let day = 86_400_000;
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.create_margin_ratios_proposal(t::perp_vk(&fx), registry, day, t::usd(2) / 10, t::usd(1) / 10, t::clock(&fx));
    });
    t::clock_mut(&mut fx).increment_for_testing(day);
    with_ch!(&mut sc, &fx, |ch| {
        ch.commit_margin_ratios_proposal(t::clock(&fx));
        assert!(ch.market_params().margin_ratio_initial() == t::usd(2) / 10);
        assert!(ch.market_params().margin_ratio_maintenance() == t::usd(1) / 10);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 26, location = perpetuals::clearing_house)]
fun proposals_cannot_be_committed_early() {
    let (mut sc, mut fx) = t::setup();
    let day = 86_400_000;
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.create_margin_ratios_proposal(t::perp_vk(&fx), registry, day, t::usd(2) / 10, t::usd(1) / 10, t::clock(&fx));
    });
    t::clock_mut(&mut fx).increment_for_testing(day - 1);
    with_ch!(&mut sc, &fx, |ch| ch.commit_margin_ratios_proposal(t::clock(&fx)));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 27, location = perpetuals::clearing_house)]
fun proposal_delay_is_bounded() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.create_margin_ratios_proposal(t::perp_vk(&fx), registry, 1_000, t::usd(2) / 10, t::usd(1) / 10, t::clock(&fx));
    });
    t::finish(sc, fx);
}

// === Freezing ===

#[test, expected_failure(abort_code = 10, location = perpetuals::clearing_house)]
fun a_frozen_clearing_house_refuses_everything() {
    let (mut sc, fx) = t::setup();
    let cap = freeze_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.freeze_clearing_house(registry, &cap);
        assert!(ch.is_frozen());
    });
    transfer::public_transfer(cap, @0x0);
    t::ladder(&mut sc, &fx, 100_000);
    t::finish(sc, fx);
}

#[test]
fun unfreezing_restores_the_version() {
    let (mut sc, fx) = t::setup();
    let cap = freeze_cap(&mut sc, &fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        let version = ch.version();
        ch.freeze_clearing_house(registry, &cap);
        assert!(ch.version() == MAX_U64);
        ch.unfreeze_clearing_house(t::perp_admin(&fx));
        assert!(!ch.is_frozen() && ch.version() == version);
    });
    transfer::public_transfer(cap, @0x0);
    t::ladder(&mut sc, &fx, 100_000);
    with_ch!(&mut sc, &fx, |ch| assert!(ch.best_price_u64(ASK) == option::some(t::px(100_000))));
    t::finish(sc, fx);
}

#[test]
fun accounts_withdraw_idle_collateral() {
    let (mut sc, fx) = t::setup();
    with_account!(&mut sc, &fx, t::taker(), |account| {
        sc.next_tx(t::admin(&fx));
        let registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
        let out = account.withdraw_collateral(t::cap(&fx, t::taker()), &registry, 30_000 * t::tusd_unit(), sc.ctx());
        assert!(out.value() == 30_000 * t::tusd_unit());
        assert!(account.collateral_balance() == 50_000 * t::tusd_unit());
        coin::burn_for_testing(out);
        ts::return_shared(registry);
    });
    t::finish(sc, fx);
}

// === Registry configuration ===

#[test]
fun registry_bounds_change_through_a_config_update() {
    let (mut sc, fx) = t::setup();
    sc.next_tx(t::admin(&fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let mut update = perpetuals::registry::new_config_update();
    update.set_account_limits(1_000_000, 7, 10);
    update.set_proposal_and_order_value_bounds(86_400_000, 259_200_000, t::usd(1), t::usd(500));
    registry.apply_config_update(t::perp_admin(&fx), update);
    let config = registry.config();
    assert!(config.up_max_pending_orders() == 7);
    assert!(config.low_min_order_usd_value() == t::usd(1) && config.up_min_order_usd_value() == t::usd(500));
    // Untouched bounds keep their values.
    assert!(config.max_assistants_per_account() == 10 && config.min_oracle_tolerance() == 500);
    ts::return_shared(registry);
    // A market may not exceed the new pending order cap, and its minimum order value has to
    // move into the new range at the same time.
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::some(t::usd(1)), option::some(7), option::none(),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(),
        );
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 1009, location = perpetuals::market)]
fun markets_are_bound_by_the_registry_pending_order_cap() {
    let (mut sc, fx) = t::setup();
    sc.next_tx(t::admin(&fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let mut update = perpetuals::registry::new_config_update();
    update.set_account_limits(1_000_000, 7, 10);
    registry.apply_config_update(t::perp_admin(&fx), update);
    ts::return_shared(registry);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::some(8), option::none(),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(),
        );
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 5008, location = perpetuals::registry)]
fun a_config_update_is_validated_as_a_whole() {
    let (mut sc, fx) = t::setup();
    sc.next_tx(t::admin(&fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let mut update = perpetuals::registry::new_config_update();
    // A minimum funding frequency above the minimum period is inconsistent.
    update.set_timing_bounds(100_000, 60_000, 864_000_000, 1_000, 60_000, 1_000, 60_000);
    registry.apply_config_update(t::perp_admin(&fx), update);
    ts::return_shared(registry);
    t::finish(sc, fx);
}
