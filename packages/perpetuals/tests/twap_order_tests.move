// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// TWAP order tickets on the `test_support` fixture: chunk scheduling, the execution gap and
/// retry window, retrying unfilled amounts, tail merging, the slippage-bounded limit price,
/// gas paid to executors pro rata, finalization, cancelation and edits.
///
/// The default order buys 1 BTC in four chunks of 0.25, one a minute, with 1% of slippage.
#[test_only]
module perpetuals::twap_order_tests;

use haneul::bcs;
use haneul::coin::{Self, Coin};
use haneul::hash;
use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::Account;
use perpetuals::clearing_house::{Self as ch, ClearingHouse, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t, with_account, with_ch};
use perpetuals::tusd::TUSD;
use perpetuals::twap_orders::{Self, TWAPOrderDetails};

const ASK: bool = true;
const BID: bool = false;
const MINUTE: u64 = 60_000;
const BUDGET: u64 = 4_000_000;

fun base(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }

/// Order parameters the tests vary.
public struct Spec has copy, drop {
    first_run_expire: Option<u64>,
    expire: Option<u64>,
    chunks: u64,
    tail_merge_bps: u64,
    retry_ms: u64,
    amount_uncertainty_bps: u64,
    max_execution_bps: u64,
    side: bool,
    size: u64,
    slippage_bps: u64,
    reduce_only: bool,
}

fun default_spec(): Spec {
    Spec {
        first_run_expire: option::none(),
        expire: option::none(),
        chunks: 4,
        tail_merge_bps: 0,
        retry_ms: 30_000,
        amount_uncertainty_bps: 0,
        max_execution_bps: 2_500,
        side: BID,
        size: t::mbtc(1_000),
        slippage_bps: 100,
        reduce_only: false,
    }
}

fun details(s: &Spec): TWAPOrderDetails {
    twap_orders::new_details(
        s.first_run_expire, s.expire, MINUTE, 10_000, s.chunks, s.tail_merge_bps, s.retry_ms,
        s.amount_uncertainty_bps, s.max_execution_bps, s.side, s.size, s.slippage_bps,
        s.reduce_only, option::none(), b"salt",
    )
}

fun commitment(s: &Spec): vector<u8> {
    hash::blake2b256(&bcs::to_bytes(&details(s)))
}

fun gas(sc: &mut Scenario, amount: u64): Coin<HANEUL> {
    coin::mint_for_testing<HANEUL>(amount, sc.ctx())
}

fun create_ticket(sc: &mut Scenario, fx: &t::Fx, who: u64, s: &Spec, budget: u64): ID {
    sc.next_tx(t::admin(fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(fx, who));
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let gas = gas(sc, budget);
    let id = twap_orders::create_twap_order_ticket(
        &mut account, t::cap(fx, who), &clearing_house, vector[t::admin(fx)], option::none(),
        gas, commitment(s), sc.ctx(),
    );
    ts::return_shared(account);
    ts::return_shared(clearing_house);
    id
}

/// Runs one chunk of `amount` as the admin; returns the summary and the gas paid out.
fun run(sc: &mut Scenario, fx: &t::Fx, who: u64, ticket: ID, s: &Spec, amount: u64): (SessionSummary, u64) {
    sc.next_tx(t::admin(fx));
    let executor = ch::no_domain_executor(sc.ctx());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(fx, who));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let d = details(s);
    let (summary, gas, clearing_house) = twap_orders::execute(
        &mut account, clearing_house, &pfs_btc, &pfs_tusd, ticket, &d, amount, t::clock(fx),
        &executor, sc.ctx(),
    );
    let paid = gas.value();
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    (summary, paid)
}

fun finalize(sc: &mut Scenario, fx: &t::Fx, who: u64, ticket: ID, s: &Spec): u64 {
    sc.next_tx(t::admin(fx));
    let executor = ch::no_domain_executor(sc.ctx());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(fx, who));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let d = details(s);
    let gas = twap_orders::finalize(
        &mut account, &mut clearing_house, &pfs_btc, &pfs_tusd, t::clock(fx), ticket, &d,
        &executor, sc.ctx(),
    );
    let left = gas.value();
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    left
}

fun ticket_state(sc: &mut Scenario, fx: &t::Fx, who: u64, ticket: ID): (u64, u64, bool) {
    sc.next_tx(t::admin(fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(fx, who));
    let exists = account.has_order_ticket(ticket);
    let (processed, unfilled) = if (exists) {
        let ticket: &mut perpetuals::twap_orders::TWAPOrderTicket<TUSD> =
            account.borrow_mut_order_ticket(ticket);
        let unfilled = ticket.unfilled_scheduled_amount();
        (if (ticket.is_complete(t::mbtc(1_000))) 1 else 0, unfilled)
    } else {
        (0, 0)
    };
    ts::return_shared(account);
    (processed, unfilled, exists)
}

/// Advances time by `ms` while keeping both feeds fresh at an unchanged price.
fun tick(sc: &mut Scenario, fx: &mut t::Fx, ms: u64) {
    t::set_price(sc, fx, 100_000, ms);
}

// === Scheduling and fills ===

#[test]
fun chunks_execute_one_a_minute_and_pay_gas_pro_rata() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    // First chunk: 0.25 BTC fills across the three ask levels, a quarter of the gas is paid.
    let (summary, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    assert!(summary.base_filled_bid() == base(250) && paid == BUDGET / 4);
    // Second chunk a minute later: only 0.05 is left on the book, so 0.05 fills and 0.2 stays
    // scheduled but unfilled; the gas follows the processed amount (0.3 of 1).
    tick(&mut sc, &mut fx, MINUTE);
    let (summary, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    assert!(summary.base_filled_bid() == base(50) && paid == BUDGET * 5 / 100);
    let (_, unfilled, _) = ticket_state(&mut sc, &fx, t::taker(), ticket);
    assert!(unfilled == t::mbtc(200));
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        // Nothing rests: chunks are immediate-or-cancel.
        assert!(base == base(300) && pending == 0);
    });
    t::finish(sc, fx);
}

#[test]
fun unfilled_amount_is_retried_when_the_executor_asks_for_less() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let mut s = default_spec();
    // Full amount uncertainty lets the executor pass any amount, down to zero.
    s.amount_uncertainty_bps = 10_000;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    tick(&mut sc, &mut fx, MINUTE);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    // The maker refills the book; a run with a zero new amount retries the unfilled 0.2.
    t::ladder(&mut sc, &fx, 100_000);
    tick(&mut sc, &mut fx, MINUTE);
    let (summary, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, 0);
    assert!(summary.base_filled_bid() == base(200) && paid == BUDGET * 20 / 100);
    let (_, unfilled, _) = ticket_state(&mut sc, &fx, t::taker(), ticket);
    assert!(unfilled == 0);
    t::finish(sc, fx);
}

#[test]
fun a_small_tail_merges_into_the_last_chunk() {
    let (mut sc, mut fx) = t::setup();
    let mut s = default_spec();
    // 1 BTC in three chunks of 0.333 leaves a 0.001 tail; merge tails below 50% of a chunk.
    s.chunks = 3;
    s.tail_merge_bps = 5_000;
    s.max_execution_bps = 4_000;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    // Deep liquidity: the maker rests 2 BTC at 100,000.
    perpetuals::test_support::session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(2_000), t::px(100_000), 0, option::none(), false, option::none());
    });
    let (summary, _) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(333));
    assert!(summary.base_filled_bid() == base(333));
    tick(&mut sc, &mut fx, MINUTE);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(333));
    tick(&mut sc, &mut fx, MINUTE);
    let (summary, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(333));
    assert!(summary.base_filled_bid() == base(334));
    // Complete: all the gas has been paid out by now.
    assert!(paid == BUDGET - BUDGET * 666 / 1000);
    let (complete, _, _) = ticket_state(&mut sc, &fx, t::taker(), ticket);
    assert!(complete == 1);
    t::finish(sc, fx);
}

#[test]
fun the_limit_price_is_the_mark_plus_slippage() {
    let (mut sc, mut fx) = t::setup();
    // Only an ask at 101,500 rests: 1.5% above the 100,000 mark, beyond the 1% slippage.
    perpetuals::test_support::session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(500), t::px(101_500), 0, option::none(), false, option::none());
    });
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    let (summary, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    assert!(summary.base_filled_bid() == 0 && paid == 0);
    // With 2% of slippage the same book fills.
    let mut wide = default_spec();
    wide.slippage_bps = 200;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &wide, BUDGET);
    tick(&mut sc, &mut fx, MINUTE);
    let (summary, _) = run(&mut sc, &fx, t::taker(), ticket, &wide, t::mbtc(250));
    assert!(summary.base_filled_bid() == base(250));
    t::finish(sc, fx);
}

#[test]
fun a_sell_twap_reduce_only_closes_a_position() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    perpetuals::test_support::session!(&mut sc, &fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(200), false);
    });
    let mut s = default_spec();
    s.side = ASK;
    s.size = t::mbtc(200);
    s.chunks = 2;
    s.max_execution_bps = 5_000;
    s.reduce_only = true;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    let (summary, _) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(100));
    assert!(summary.base_filled_ask() == base(100));
    tick(&mut sc, &mut fx, MINUTE);
    let (summary, _) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(100));
    assert!(summary.base_filled_ask() == base(100));
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == 0);
    });
    t::finish(sc, fx);
}

// === Timing rules ===

#[test, expected_failure(abort_code = 6303, location = perpetuals::twap_orders)]
fun chunks_respect_the_execution_gap() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    // 49 s later is more than the 10 s of uncertainty short of the minute.
    tick(&mut sc, &mut fx, 49_000);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

#[test]
fun chunks_may_run_within_the_gap_uncertainty() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    tick(&mut sc, &mut fx, 50_000);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6305, location = perpetuals::twap_orders)]
fun an_order_spoils_after_the_retry_window() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    // Retry window: 30 s of retry + 60 s of gap + 10 s of uncertainty from the last fill.
    tick(&mut sc, &mut fx, 100_000);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6310, location = perpetuals::twap_orders)]
fun the_first_run_has_its_own_deadline() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let mut s = default_spec();
    s.first_run_expire = option::some(t::clock(&fx).timestamp_ms() + 1_000);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    tick(&mut sc, &mut fx, 2_000);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6301, location = perpetuals::twap_orders)]
fun an_expired_order_cannot_run() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let mut s = default_spec();
    s.expire = option::some(t::clock(&fx).timestamp_ms() + 1_000);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    tick(&mut sc, &mut fx, 2_000);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

// === Validation ===

#[test, expected_failure(abort_code = 6300, location = perpetuals::twap_orders)]
fun details_need_at_least_one_lot_per_chunk() {
    twap_orders::new_details(
        option::none(), option::none(), MINUTE, 10_000, 5, 0, 30_000, 0, 2_500, BID, 4, 100,
        false, option::none(), b"salt",
    );
}

#[test, expected_failure(abort_code = 6300, location = perpetuals::twap_orders)]
fun revealed_details_must_match_the_ticket() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    let mut other = s;
    other.slippage_bps = 300;
    run(&mut sc, &fx, t::taker(), ticket, &other, t::mbtc(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6302, location = perpetuals::twap_orders)]
fun the_amount_must_be_within_the_uncertainty_of_a_chunk() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(200));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6312, location = perpetuals::twap_orders)]
fun the_size_must_be_lot_compatible() {
    let (mut sc, fx) = t::setup();
    let mut s = default_spec();
    s.size = t::mbtc(1_000) + 1;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6306, location = perpetuals::twap_orders)]
fun only_listed_executors_may_run() {
    let (mut sc, fx) = t::setup();
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    sc.next_tx(@0xBEEF);
    let executor = ch::no_domain_executor(sc.ctx());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(&fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(&fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(&fx));
    let d = details(&s);
    let (_, gas, clearing_house) = twap_orders::execute(
        &mut account, clearing_house, &pfs_btc, &pfs_tusd, ticket, &d, t::mbtc(250), t::clock(&fx),
        &executor, sc.ctx(),
    );
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    t::finish(sc, fx);
}

// === Lifecycle ===

#[test]
fun finalize_pays_the_rest_of_the_gas_and_frees_collateral() {
    let (mut sc, mut fx) = t::setup();
    let mut s = default_spec();
    s.chunks = 2;
    s.max_execution_bps = 5_000;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    perpetuals::test_support::session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(2_000), t::px(100_000), 0, option::none(), false, option::none());
    });
    let (_, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(500));
    assert!(paid == BUDGET / 2);
    tick(&mut sc, &mut fx, MINUTE);
    let (_, paid) = run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(500));
    assert!(paid == BUDGET / 2);
    // Everything was paid during execution; finalize returns the empty remainder, removes the
    // ticket and moves the taker's free collateral back to the account.
    let left = finalize(&mut sc, &fx, t::taker(), ticket, &s);
    assert!(left == 0);
    let (_, _, exists) = ticket_state(&mut sc, &fx, t::taker(), ticket);
    assert!(!exists);
    with_account!(&mut sc, &fx, t::taker(), |account| {
        // 1 BTC at 100,000 needs 10,000 of margin; the 50 of fees came out of the allocation.
        assert!(account.collateral_balance() == (80_000 + 20_000 - 50 - 10_000) * t::tusd_unit());
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6308, location = perpetuals::twap_orders)]
fun finalize_needs_a_completed_order() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    finalize(&mut sc, &fx, t::taker(), ticket, &s);
    t::finish(sc, fx);
}

#[test]
fun cancel_returns_the_unpaid_gas() {
    let (mut sc, mut fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    tick(&mut sc, &mut fx, MINUTE);
    // The user cancels: three quarters of the budget come back and free collateral is released.
    sc.next_tx(t::admin(&fx));
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(&fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(&fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(&fx));
    let gas = twap_orders::user_cancel_twap_order(
        &mut account, t::cap(&fx, t::taker()), &mut clearing_house, &pfs_btc, &pfs_tusd, ticket,
        t::clock(&fx), sc.ctx(),
    );
    assert!(gas.value() == BUDGET * 3 / 4 && !account.has_order_ticket(ticket));
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    // An untouched ticket canceled by its executor returns the whole budget.
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    sc.next_tx(t::admin(&fx));
    let executor = ch::no_domain_executor(sc.ctx());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(&fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(&fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(&fx));
    let gas = twap_orders::cancel(
        &mut account, &mut clearing_house, &pfs_btc, &pfs_tusd, ticket, t::clock(&fx), &executor,
        sc.ctx(),
    );
    assert!(gas.value() == BUDGET);
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6307, location = perpetuals::twap_orders)]
fun a_started_order_cannot_be_edited() {
    let (mut sc, fx) = t::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    run(&mut sc, &fx, t::taker(), ticket, &s, t::mbtc(250));
    sc.next_tx(t::admin(&fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    twap_orders::set_details(&mut account, t::cap(&fx, t::taker()), &registry, ticket, b"new");
    ts::return_shared(account);
    ts::return_shared(registry);
    t::finish(sc, fx);
}

#[test]
fun an_unstarted_order_can_be_edited() {
    let (mut sc, fx) = t::setup();
    let s = default_spec();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), &s, BUDGET);
    sc.next_tx(t::admin(&fx));
    let mut account = sc.take_shared_by_id<Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let mut other = s;
    other.slippage_bps = 300;
    twap_orders::set_details(&mut account, t::cap(&fx, t::taker()), &registry, ticket, commitment(&other));
    twap_orders::set_executors(&mut account, t::cap(&fx, t::taker()), &registry, ticket, vector[t::admin(&fx), @0x1]);
    ts::return_shared(account);
    ts::return_shared(registry);
    // The edited details are what runs now.
    t::ladder(&mut sc, &fx, 100_000);
    let (summary, _) = run(&mut sc, &fx, t::taker(), ticket, &other, t::mbtc(250));
    assert!(summary.base_filled_bid() == base(250));
    t::finish(sc, fx);
}
