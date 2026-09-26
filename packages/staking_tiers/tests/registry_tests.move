// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module staking_tiers::registry_tests;

use haneul::clock;
use haneul::test_scenario as ts;
use haneul_system::staking_pool::StakedHaneul;
use haneul_system::test_runner;
use haneul_system::validator_builder;
use staking_tiers::registry::{Self, AdminCap, TierRegistry};

const VALIDATOR: address = @0x1;
const STAKER: address = @0x2;
const OTHER: address = @0x3;
const HANEUL: u64 = 1_000_000_000;
const DAY_MS: u64 = 86_400_000;

/// A system with one validator, and `amount` HANEUL staked by `STAKER` returned as an object.
fun staked(amount: u64): (test_runner::TestRunner, StakedHaneul) {
    let validator = validator_builder::new().initial_stake(100).haneul_address(VALIDATOR);
    let mut runner = test_runner::new().validators(vector[validator]).build();
    runner.set_sender(STAKER);
    let stake = runner.stake_with_and_take(VALIDATOR, amount);
    (runner, stake)
}

fun setup(): (test_runner::TestRunner, StakedHaneul, TierRegistry, AdminCap) {
    let (mut runner, stake) = staked(60);
    runner.set_sender(STAKER);
    registry::init_for_testing(runner.ctx());
    let scenario = runner.scenario_mut();
    scenario.next_tx(STAKER);
    let registry = scenario.take_shared<TierRegistry>();
    let cap = scenario.take_from_sender<AdminCap>();
    (runner, stake, registry, cap)
}

fun teardown(runner: test_runner::TestRunner, registry: TierRegistry, cap: AdminCap) {
    ts::return_shared(registry);
    transfer::public_transfer(cap, STAKER);
    runner.finish();
}

#[test]
fun deposit_counts_at_once_and_tiers_follow_thresholds() {
    let (mut runner, stake, mut registry, cap) = setup();
    registry.set_thresholds(&cap, vector[10 * HANEUL, 50 * HANEUL, 100 * HANEUL]);
    assert!(registry.tier(STAKER) == 0);
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    assert!(registry.active_stake(STAKER) == 60 * HANEUL);
    assert!(registry.pending_stake(STAKER) == 0);
    assert!(registry.tier(STAKER) == 2);
    assert!(registry.tier(OTHER) == 0);
    assert!(registry.has_deposit(stake_id));
    assert!(registry.deposit_owner(stake_id) == STAKER);
    assert!(registry.deposit_principal(stake_id) == 60 * HANEUL);
    assert!(registry.deposit_unlock_ms(stake_id).is_none());
    assert!(registry.tier_for_stake(100 * HANEUL) == 3);
    teardown(runner, registry, cap);
}

#[test]
fun withdrawal_waits_out_the_delay_and_drops_the_tier_immediately() {
    let (mut runner, stake, mut registry, cap) = setup();
    registry.set_thresholds(&cap, vector[10 * HANEUL]);
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let mut clock = clock::create_for_testing(runner.ctx());
    clock.set_for_testing(1_000);
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    assert!(registry.active_stake(STAKER) == 0);
    assert!(registry.pending_stake(STAKER) == 60 * HANEUL);
    assert!(registry.tier(STAKER) == 0);
    assert!(registry.deposit_unlock_ms(stake_id) == option::some(1_000 + 7 * DAY_MS));
    clock.set_for_testing(1_000 + 7 * DAY_MS);
    let stake = registry.withdraw(stake_id, &clock, runner.ctx());
    assert!(stake.staked_haneul_amount() == 60 * HANEUL);
    assert!(registry.pending_stake(STAKER) == 0);
    assert!(!registry.has_deposit(stake_id));
    transfer::public_transfer(stake, STAKER);
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test]
fun canceling_a_withdrawal_restores_the_tier() {
    let (mut runner, stake, mut registry, cap) = setup();
    registry.set_thresholds(&cap, vector[10 * HANEUL]);
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let clock = clock::create_for_testing(runner.ctx());
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    assert!(registry.tier(STAKER) == 0);
    registry.cancel_withdrawal(stake_id, runner.ctx());
    assert!(registry.active_stake(STAKER) == 60 * HANEUL);
    assert!(registry.pending_stake(STAKER) == 0);
    assert!(registry.tier(STAKER) == 1);
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test, expected_failure(abort_code = registry::EWithdrawalDelayNotElapsed)]
fun withdrawing_early_aborts() {
    let (mut runner, stake, mut registry, cap) = setup();
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let mut clock = clock::create_for_testing(runner.ctx());
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    clock.set_for_testing(7 * DAY_MS - 1);
    let stake = registry.withdraw(stake_id, &clock, runner.ctx());
    transfer::public_transfer(stake, STAKER);
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test, expected_failure(abort_code = registry::EWithdrawalNotRequested)]
fun withdrawing_without_a_request_aborts() {
    let (mut runner, stake, mut registry, cap) = setup();
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let clock = clock::create_for_testing(runner.ctx());
    let stake = registry.withdraw(stake_id, &clock, runner.ctx());
    transfer::public_transfer(stake, STAKER);
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test, expected_failure(abort_code = registry::ENotDepositOwner)]
fun only_the_depositor_can_request_a_withdrawal() {
    let (mut runner, stake, mut registry, cap) = setup();
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let clock = clock::create_for_testing(runner.ctx());
    runner.set_sender(OTHER);
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test, expected_failure(abort_code = registry::EWithdrawalAlreadyRequested)]
fun a_second_request_aborts() {
    let (mut runner, stake, mut registry, cap) = setup();
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let clock = clock::create_for_testing(runner.ctx());
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}

#[test, expected_failure(abort_code = registry::EThresholdsNotAscending)]
fun thresholds_must_ascend() {
    let (runner, stake, mut registry, cap) = setup();
    registry.set_thresholds(&cap, vector[10 * HANEUL, 10 * HANEUL]);
    transfer::public_transfer(stake, STAKER);
    teardown(runner, registry, cap);
}

#[test]
fun admin_changes_the_delay() {
    let (mut runner, stake, mut registry, cap) = setup();
    registry.set_withdraw_delay_ms(&cap, DAY_MS);
    assert!(registry.withdraw_delay_ms() == DAY_MS);
    let stake_id = object::id(&stake);
    registry.deposit(stake, runner.ctx());
    let mut clock = clock::create_for_testing(runner.ctx());
    registry.request_withdrawal(stake_id, &clock, runner.ctx());
    clock.set_for_testing(DAY_MS);
    let stake = registry.withdraw(stake_id, &clock, runner.ctx());
    transfer::public_transfer(stake, STAKER);
    clock.destroy_for_testing();
    teardown(runner, registry, cap);
}
