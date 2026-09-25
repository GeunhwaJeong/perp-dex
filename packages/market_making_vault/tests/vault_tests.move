// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Vault tests: deposits and LP pricing, the withdraw request lifecycle, owner-processed
/// withdrawals with the owner fee, and the forced withdrawal path that closes part of the
/// vault's position to free a departing LP's share, with its margin band and pause window.
///
/// The vault starts with 1 TUSD of owner-locked liquidity. Prices are held at 100,000 so the
/// mark equals the index; the fixture market's maker ladder provides the liquidity.
#[test_only]
module market_making_vault::vault_tests;

use market_making_vault::vault::UserLpCoin;
use market_making_vault::vault_test_support::{Self as v};
use market_making_vault::vlp::VLP;
use perpetuals::test_support::{Self as t, with_ch};

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const ASK: bool = true;
const BID: bool = false;

fun lp_of(coin: &UserLpCoin<VLP>): u64 {
    let (lp, _) = market_making_vault::vault::user_lp_coin_info(coin);
    lp
}

fun park(coin: UserLpCoin<VLP>) {
    transfer::public_transfer(coin, @0x0)
}

fun tusd(units: u64): u64 { units * t::tusd_unit() }

/// Alice deposits 10,000; the vault allocates 5,000 to the market and buys 0.1 BTC at 100,000
/// (5 of fees), leaving 5,001 idle and 4,995 of margin: a vault worth 9,996.
fun funded_vault_with_a_long(sc: &mut haneul::test_scenario::Scenario, fx: &t::Fx, vf: &v::VFx): UserLpCoin<VLP> {
    let lp = v::deposit(sc, fx, vf, ALICE, tusd(10_000));
    t::ladder(sc, fx, 100_000);
    v::vault_enters_market(sc, fx, vf, tusd(5_000));
    v::vault_market_order(sc, fx, vf, BID, t::mbtc(100), false);
    lp
}

// === Fixture and deposits ===

#[test]
fun the_vault_starts_with_the_owners_locked_liquidity() {
    let (mut sc, fx, vf) = v::setup();
    let (supply, idle, fees) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(1) && idle == tusd(1) && fees == 0);
    v::finish(sc, fx, vf);
}

#[test]
fun a_deposit_into_a_cash_only_vault_mints_lp_one_to_one() {
    let (mut sc, fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    assert!(lp_of(&lp) == tusd(10_000));
    let (supply, idle, _) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(10_001) && idle == tusd(10_001));
    park(lp);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 26, location = market_making_vault::vault)]
fun deposits_below_the_minimum_are_refused() {
    let (mut sc, fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, t::tusd_unit() / 2);
    park(lp);
    v::finish(sc, fx, vf);
}

#[test]
fun lp_is_priced_on_the_vaults_margin_in_its_markets() {
    let (mut sc, fx, vf) = v::setup();
    let alice = funded_vault_with_a_long(&mut sc, &fx, &vf);
    // Bob's 5,000 buys LP at 9,996 / 10,001 per unit: 5,002.501 LP.
    let bob = v::deposit(&mut sc, &fx, &vf, BOB, tusd(5_000));
    assert!(lp_of(&bob) == 5_002_501_000);
    let (supply, idle, _) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(10_001) + 5_002_501_000);
    // The whole deposit was taken (at most one unit of rounding is refunded).
    assert!(idle >= tusd(5_001 + 5_000) - 1 && idle <= tusd(5_001 + 5_000));
    park(alice);
    park(bob);
    v::finish(sc, fx, vf);
}

// === Withdraw requests ===

#[test, expected_failure(abort_code = 14, location = market_making_vault::vault)]
fun requests_wait_for_the_lock_period() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms() - 1);
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 28, location = market_making_vault::vault)]
fun one_request_per_address() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    // Half now, and the rest of the coin comes back to Alice for a second request.
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(5_000), 0);
    sc.next_tx(ALICE);
    let rest = sc.take_from_sender<UserLpCoin<VLP>>();
    assert!(lp_of(&rest) == tusd(5_000));
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, rest, tusd(5_000), 0);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 11, location = market_making_vault::vault)]
fun requests_cannot_exceed_the_coin() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_001), 0);
    v::finish(sc, fx, vf);
}

#[test]
fun a_request_can_be_withdrawn_again() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared_by_id<market_making_vault::vault::Vault<VLP, perpetuals::tusd::TUSD>>(v::vault_id(&vf));
    let lp = market_making_vault::interface::remove_withdraw_request(&mut vault, sc.ctx());
    assert!(lp_of(&lp) == tusd(10_000));
    haneul::test_scenario::return_shared(vault);
    park(lp);
    v::finish(sc, fx, vf);
}

// === Owner-processed withdrawals ===

#[test]
fun the_owner_pays_out_a_request_and_keeps_a_fee_on_the_profit() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    // 100 of yield: the vault is worth 10,101 for 10,001 LP.
    v::add_yield(&mut sc, &fx, &vf, tusd(100));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    let out = v::owner_process_withdraw(&mut sc, &fx, &vf, ALICE);
    // Alice's share is 10,099.99; 10% of the 99.99 of profit stays as the owner fee.
    assert!(out == 10_089_991_000);
    let (supply, idle, fees) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(1) && fees == 9_999_000);
    assert!(idle == tusd(10_101) - 10_099_990_000);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 1, location = market_making_vault::vault)]
fun a_request_can_set_a_minimum_it_will_not_go_below() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), tusd(10_001));
    v::owner_process_withdraw(&mut sc, &fx, &vf, ALICE);
    v::finish(sc, fx, vf);
}

#[test]
fun the_treasury_collects_the_owner_fees() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::add_yield(&mut sc, &fx, &vf, tusd(100));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::owner_process_withdraw(&mut sc, &fx, &vf, ALICE);
    sc.next_tx(t::admin(&fx));
    let mut vault = sc.take_shared_by_id<market_making_vault::vault::Vault<VLP, perpetuals::tusd::TUSD>>(v::vault_id(&vf));
    let fees = market_making_vault::interface::withdraw_fees(&mut vault, v::treasury_cap(&vf), 9_999_000, sc.ctx());
    assert!(fees.value() == 9_999_000);
    haneul::coin::burn_for_testing(fees);
    haneul::test_scenario::return_shared(vault);
    let (_, _, left) = v::vault_state(&mut sc, &vf);
    assert!(left == 0);
    v::finish(sc, fx, vf);
}

// === Forced withdrawals ===

#[test, expected_failure(abort_code = 5, location = market_making_vault::vault)]
fun a_forced_withdrawal_waits_for_the_delay() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms() - 1);
    v::force_withdraw(&mut sc, &fx, &vf, ALICE, 0, vector[]);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 30, location = market_making_vault::vault)]
fun a_forced_withdrawal_needs_a_request() {
    let (mut sc, fx, vf) = v::setup();
    v::force_withdraw(&mut sc, &fx, &vf, ALICE, 0, vector[]);
    v::finish(sc, fx, vf);
}

#[test]
fun a_forced_withdrawal_from_a_cash_only_vault_pays_the_share() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = v::deposit(&mut sc, &fx, &vf, ALICE, tusd(10_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    let out = v::force_withdraw(&mut sc, &fx, &vf, ALICE, 0, vector[]);
    assert!(out == tusd(10_000));
    let (supply, idle, _) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(1) && idle == tusd(1));
    v::finish(sc, fx, vf);
}

#[test]
fun a_forced_withdrawal_closes_the_position_for_a_dominant_share() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    // Alice holds 10,000 of 10,001 LP: the whole 0.1 BTC is sold into the 99,900 bid, costing
    // her 10 of slippage and 4.995 of fees on top of her 9,995.0005 share.
    let out = v::force_withdraw(&mut sc, &fx, &vf, ALICE, t::mbtc(100), vector[]);
    assert!(out >= 9_980_005_490 && out <= 9_980_005_500);
    // The vault's position is flat and emptied of collateral.
    let vault_account = v::vault_account_id(&mut sc, &vf);
    with_ch!(&mut sc, &fx, |ch| {
        let (collateral, base, _, _, _, pending) = t::position_of(ch, vault_account);
        assert!(collateral == 0 && base == 0 && pending == 0);
    });
    let (supply, idle, _) = v::vault_state(&mut sc, &vf);
    // Only the owner's LP is left, backed by its share of what remains.
    assert!(supply == tusd(1));
    assert!(idle + out == tusd(5_001) + 4_980_005_000);
    assert!(!v::ch_in_vault(&mut sc, &vf, &fx));
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 47, location = market_making_vault::vault)]
fun a_small_share_cannot_close_the_whole_position() {
    let (mut sc, mut fx, vf) = v::setup();
    let alice = funded_vault_with_a_long(&mut sc, &fx, &vf);
    // Bob's 1,000 is about a tenth of the vault.
    let bob = v::deposit(&mut sc, &fx, &vf, BOB, tusd(1_000));
    let bob_lp = lp_of(&bob);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, BOB, bob, bob_lp, 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    // Closing everything would leave 4,000 of collateral in the market: refused.
    v::force_withdraw(&mut sc, &fx, &vf, BOB, t::mbtc(100), vector[]);
    park(alice);
    v::finish(sc, fx, vf);
}

#[test]
fun a_small_share_closes_just_enough_of_the_position() {
    let (mut sc, mut fx, vf) = v::setup();
    let alice = funded_vault_with_a_long(&mut sc, &fx, &vf);
    let bob = v::deposit(&mut sc, &fx, &vf, BOB, tusd(1_000));
    let bob_lp = lp_of(&bob);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, BOB, bob, bob_lp, 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    // Bob holds 9.09% of the vault, so 454 of the market's 4,995 of margin is his. Freeing it
    // while keeping the rest of the position at its 49.95% margin ratio takes closing exactly
    // 0.010 BTC: 0.009 leaves the position under the ratio and 0.011 closes more than needed.
    let out = v::force_withdraw(&mut sc, &fx, &vf, BOB, t::mbtc(10), vector[]);
    // His 1,000 share minus the 1.4995 of slippage and fees on the 0.010 BTC closed.
    assert!(out >= 998_400_000 && out <= 998_600_000);
    let (supply, _, _) = v::vault_state(&mut sc, &vf);
    assert!(supply == tusd(10_001));
    assert!(v::ch_in_vault(&mut sc, &vf, &fx));
    park(alice);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 9, location = market_making_vault::vault)]
fun closing_too_little_leaves_the_position_under_its_margin_ratio() {
    let (mut sc, mut fx, vf) = v::setup();
    let alice = funded_vault_with_a_long(&mut sc, &fx, &vf);
    let bob = v::deposit(&mut sc, &fx, &vf, BOB, tusd(1_000));
    let bob_lp = lp_of(&bob);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, BOB, bob, bob_lp, 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::force_withdraw(&mut sc, &fx, &vf, BOB, t::mbtc(9), vector[]);
    park(alice);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 13, location = market_making_vault::vault)]
fun closing_too_much_is_refused() {
    let (mut sc, mut fx, vf) = v::setup();
    let alice = funded_vault_with_a_long(&mut sc, &fx, &vf);
    let bob = v::deposit(&mut sc, &fx, &vf, BOB, tusd(1_000));
    let bob_lp = lp_of(&bob);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, BOB, bob, bob_lp, 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::force_withdraw(&mut sc, &fx, &vf, BOB, t::mbtc(11), vector[]);
    park(alice);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 12, location = market_making_vault::vault)]
fun the_vaults_resting_orders_must_be_canceled_first() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::vault_limit_order(&mut sc, &fx, &vf, ASK, t::mbtc(10), t::px(105_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::force_withdraw(&mut sc, &fx, &vf, ALICE, t::mbtc(100), vector[]);
    v::finish(sc, fx, vf);
}

#[test]
fun the_vaults_resting_orders_are_canceled_when_listed() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    let order = v::vault_limit_order(&mut sc, &fx, &vf, ASK, t::mbtc(10), t::px(105_000));
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    let out = v::force_withdraw(&mut sc, &fx, &vf, ALICE, t::mbtc(100), vector[order]);
    assert!(out >= 9_980_005_490 && out <= 9_980_005_500);
    with_ch!(&mut sc, &fx, |ch| assert!(ch.best_price_u64(ASK) == option::some(t::px(100_100))));
    v::finish(sc, fx, vf);
}

// === The force-withdraw pause ===

#[test, expected_failure(abort_code = 15, location = market_making_vault::vault)]
fun a_matured_request_can_pause_the_vaults_trading() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::pause_for_force_withdraw(&mut sc, &fx, &vf, ALICE);
    // The owner cannot trade during the window.
    v::vault_market_order(&mut sc, &fx, &vf, BID, t::mbtc(10), false);
    v::finish(sc, fx, vf);
}

#[test]
fun the_pause_lifts_after_its_window() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::pause_for_force_withdraw(&mut sc, &fx, &vf, ALICE);
    // The package config pauses for 10 s.
    v::wait(&mut sc, &mut fx, 10_000);
    v::resume_after_force_withdraw_pause(&mut sc, &fx, &vf);
    v::vault_market_order(&mut sc, &fx, &vf, BID, t::mbtc(10), false);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 46, location = market_making_vault::vault)]
fun pauses_are_rate_limited() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::wait(&mut sc, &mut fx, v::force_delay_ms());
    v::pause_for_force_withdraw(&mut sc, &fx, &vf, ALICE);
    v::wait(&mut sc, &mut fx, 10_000);
    v::resume_after_force_withdraw_pause(&mut sc, &fx, &vf);
    // Less than the 30 minute minimum between pauses.
    v::pause_for_force_withdraw(&mut sc, &fx, &vf, ALICE);
    v::finish(sc, fx, vf);
}

#[test, expected_failure(abort_code = 5, location = market_making_vault::vault)]
fun the_pause_needs_a_matured_request() {
    let (mut sc, mut fx, vf) = v::setup();
    let lp = funded_vault_with_a_long(&mut sc, &fx, &vf);
    v::wait(&mut sc, &mut fx, v::lock_ms());
    v::request_withdraw(&mut sc, &fx, &vf, ALICE, lp, tusd(10_000), 0);
    v::pause_for_force_withdraw(&mut sc, &fx, &vf, ALICE);
    v::finish(sc, fx, vf);
}
