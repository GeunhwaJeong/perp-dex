// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Stop order tickets on the `test_support` fixture: stop loss / take profit tickets on a
/// position and standalone stop tickets, their trigger price types, the commitment check, the
/// executor and domain checks, expiry, gas, cancelation and edits.
///
/// A ticket only stores `blake2b256(bcs(order details) || salt)`; the executor reveals the
/// details at execution time, so the tests build the same byte string the module checks.
#[test_only]
module perpetuals_orders::stop_order_tests;

use haneul::bcs;
use haneul::coin::{Self, Coin};
use haneul::hash;
use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use perpetuals::account::IntegratorInfo;
use perpetuals::clearing_house::{Self as ch, ClearingHouse, Executor, SessionSummary};
use perpetuals::registry::Registry;
use perpetuals_orders::stop_orders;
use perpetuals_orders::orders_test_support as os;
use perpetuals::test_support::{Self as t, session, with_ch};
use perpetuals::tusd::TUSD;

const ASK: bool = true;
const BID: bool = false;
const INDEX: u8 = 0;
const BOOK: u8 = 1;
const MARK: u8 = 2;
const SLTP: u64 = 0;
const STANDALONE: u64 = 1;
const GAS: u64 = 1_000_000;

fun base(thousandths: u64): u256 { (thousandths as u256) * 1_000_000_000_000_000 }

/// The details of a stop loss / take profit ticket.
public struct Sltp has copy, drop {
    expire: Option<u64>,
    is_limit: bool,
    trigger: u8,
    stop_loss: Option<u256>,
    take_profit: Option<u256>,
    position_is_ask: bool,
    size: u64,
    price: u64,
    order_type: u64,
    integrator: Option<IntegratorInfo>,
    salt: vector<u8>,
}

/// A market close of a 0.25 BTC long with a stop loss at 95,000 and a take profit at 105,000,
/// triggered on the index price.
fun default_sltp(): Sltp {
    Sltp {
        expire: option::none(),
        is_limit: false,
        trigger: INDEX,
        stop_loss: option::some(t::usd(95_000)),
        take_profit: option::some(t::usd(105_000)),
        position_is_ask: false,
        size: t::mbtc(250),
        price: 0,
        order_type: 0,
        integrator: option::none(),
        salt: b"salt",
    }
}

fun sltp_commitment(ch_id: ID, d: &Sltp): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&ch_id));
    bytes.append(bcs::to_bytes(&d.expire));
    bytes.append(bcs::to_bytes(&d.is_limit));
    bytes.append(bcs::to_bytes(&d.trigger));
    bytes.append(bcs::to_bytes(&d.stop_loss));
    bytes.append(bcs::to_bytes(&d.take_profit));
    bytes.append(bcs::to_bytes(&d.position_is_ask));
    bytes.append(bcs::to_bytes(&d.size));
    bytes.append(bcs::to_bytes(&d.price));
    bytes.append(bcs::to_bytes(&d.order_type));
    bytes.append(bcs::to_bytes(&d.integrator));
    bytes.append(d.salt);
    hash::blake2b256(&bytes)
}

/// The details of a standalone stop ticket.
public struct Standalone has copy, drop {
    expire: Option<u64>,
    is_limit: bool,
    trigger: u8,
    stop_index_price: u256,
    ge: bool,
    side: bool,
    size: u64,
    price: u64,
    order_type: u64,
    reduce_only: bool,
    integrator: Option<IntegratorInfo>,
    salt: vector<u8>,
}

/// A 0.1 BTC market buy once the index is at or above 101,000.
fun default_standalone(): Standalone {
    Standalone {
        expire: option::none(),
        is_limit: false,
        trigger: INDEX,
        stop_index_price: t::usd(101_000),
        ge: true,
        side: BID,
        size: t::mbtc(100),
        price: 0,
        order_type: 0,
        reduce_only: false,
        integrator: option::none(),
        salt: b"salt",
    }
}

fun standalone_commitment(ch_id: ID, d: &Standalone): vector<u8> {
    let mut bytes = vector[];
    bytes.append(bcs::to_bytes(&ch_id));
    bytes.append(bcs::to_bytes(&d.expire));
    bytes.append(bcs::to_bytes(&d.is_limit));
    bytes.append(bcs::to_bytes(&d.trigger));
    bytes.append(bcs::to_bytes(&d.stop_index_price));
    bytes.append(bcs::to_bytes(&d.ge));
    bytes.append(bcs::to_bytes(&d.side));
    bytes.append(bcs::to_bytes(&d.size));
    bytes.append(bcs::to_bytes(&d.price));
    bytes.append(bcs::to_bytes(&d.order_type));
    bytes.append(bcs::to_bytes(&d.reduce_only));
    bytes.append(bcs::to_bytes(&d.integrator));
    bytes.append(d.salt);
    hash::blake2b256(&bytes)
}

fun gas(sc: &mut Scenario, amount: u64): Coin<HANEUL> {
    coin::mint_for_testing<HANEUL>(amount, sc.ctx())
}

/// Creates a ticket for `who`, executable by the fixture admin, with the given commitment.
fun create_ticket(
    sc: &mut Scenario,
    fx: &t::Fx,
    who: u64,
    stop_order_type: u64,
    commitment: vector<u8>,
    domain: Option<address>,
    gas_amount: u64,
): ID {
    sc.next_tx(t::admin(fx));
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(t::account_obj(fx, who));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let gas = gas(sc, gas_amount);
    let id = stop_orders::create_stop_order_ticket(
        &mut account, t::cap(fx, who), &registry, vector[t::admin(fx)], domain, gas,
        stop_order_type, commitment, sc.ctx(),
    );
    assert!(account.has_order_ticket(id));
    ts::return_shared(account);
    ts::return_shared(registry);
    id
}

/// Executes an SLTP ticket as `sender`; returns the summary and the gas paid to the executor.
fun run_sltp(sc: &mut Scenario, fx: &t::Fx, who: u64, ticket: ID, d: &Sltp, sender: address, executor: &Executor): (SessionSummary, u64) {
    sc.next_tx(sender);
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(t::account_obj(fx, who));
    let pfs_btc = sc.take_shared_by_id<oracle_aggregator::price_feed_storage::PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<oracle_aggregator::price_feed_storage::PriceFeedStorage>(t::pfs_tusd_id(fx));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let (summary, gas, clearing_house) = stop_orders::place_stop_order_sltp(
        clearing_house, &pfs_btc, &pfs_tusd, t::clock(fx), &registry, ticket, &mut account,
        d.expire, d.is_limit, d.trigger, d.stop_loss, d.take_profit, d.position_is_ask,
        d.size, d.price, d.order_type, d.salt, d.integrator, executor, sc.ctx(),
    );
    let paid = gas.value();
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    ts::return_shared(registry);
    (summary, paid)
}

fun run_standalone(sc: &mut Scenario, fx: &t::Fx, who: u64, ticket: ID, d: &Standalone): (SessionSummary, u64) {
    sc.next_tx(t::admin(fx));
    let executor = ch::no_domain_executor(sc.ctx());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(t::account_obj(fx, who));
    let pfs_btc = sc.take_shared_by_id<oracle_aggregator::price_feed_storage::PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<oracle_aggregator::price_feed_storage::PriceFeedStorage>(t::pfs_tusd_id(fx));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let (summary, gas, clearing_house) = stop_orders::place_stop_order_standalone(
        clearing_house, &pfs_btc, &pfs_tusd, t::clock(fx), &registry, ticket, &mut account,
        d.expire, d.is_limit, d.trigger, d.stop_index_price, d.ge, d.side, d.size, d.price,
        d.order_type, d.reduce_only, d.salt, d.integrator, &executor, sc.ctx(),
    );
    let paid = gas.value();
    coin::burn_for_testing(gas);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    ts::return_shared(registry);
    (summary, paid)
}

/// The admin executes an SLTP ticket for the taker.
fun exec(sc: &mut Scenario, fx: &t::Fx, ticket: ID, d: &Sltp): (SessionSummary, u64) {
    sc.next_tx(t::admin(fx));
    let executor = ch::no_domain_executor(sc.ctx());
    run_sltp(sc, fx, t::taker(), ticket, d, t::admin(fx), &executor)
}

/// Ladder plus a 0.25 BTC taker long at an average of 100,080.
fun long_setup(sc: &mut Scenario, fx: &t::Fx) {
    t::ladder(sc, fx, 100_000);
    session!(sc, fx, t::taker(), false, false, |hp| {
        hp.place_market_order(BID, t::mbtc(250), false);
    });
}

// === Stop loss / take profit ===

#[test]
fun stop_loss_closes_the_long_when_the_index_falls() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    let (summary, paid) = exec(&mut sc, &fx, ticket, &d);
    // The whole position is sold into the resting bids and the executor keeps the gas.
    assert!(summary.base_filled_ask() == base(250) && paid == GAS);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == 0 && pending == 0);
    });
    t::finish(sc, fx);
}

#[test]
fun take_profit_closes_the_long_when_the_index_rises() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 106_000, 100);
    let (summary, _) = exec(&mut sc, &fx, ticket, &d);
    assert!(summary.base_filled_ask() == base(250));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6201, location = perpetuals_orders::stop_orders)]
fun sltp_does_not_trigger_between_the_levels() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 97_000, 100);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

#[test]
fun sltp_size_is_clipped_to_the_position() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let mut d = default_sltp();
    d.size = t::mbtc(1_000);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    let (summary, _) = exec(&mut sc, &fx, ticket, &d);
    assert!(summary.base_filled_ask() == base(250));
    t::finish(sc, fx);
}

#[test]
fun sltp_limit_order_rests_reduce_only() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    // A limit sell at 101,000 above the bids: it rests as a reduce-only order.
    let mut d = default_sltp();
    d.is_limit = true;
    d.price = t::px(101_000);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    let (summary, _) = exec(&mut sc, &fx, ticket, &d);
    assert!(summary.base_filled_ask() == 0 && summary.posted_orders() == 1);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, asks, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(250) && asks == base(250) && pending == 1);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6206, location = perpetuals_orders::stop_orders)]
fun sltp_checks_the_position_side() {
    let (mut sc, fx) = os::setup();
    long_setup(&mut sc, &fx);
    // Committed as a short's stop loss (trigger at or above 90,000) while the position is long.
    let mut d = default_sltp();
    d.position_is_ask = true;
    d.stop_loss = option::some(t::usd(90_000));
    d.take_profit = option::none();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

#[test]
fun book_and_mark_trigger_types() {
    let (mut sc, fx) = os::setup();
    long_setup(&mut sc, &fx);
    // After the 0.25 buy the book is 100,200 / 99,900, a mid of 100,050, while the index is
    // 100,000: a take profit at 100,040 fires on the book price only.
    let mut d = default_sltp();
    d.trigger = BOOK;
    d.stop_loss = option::none();
    d.take_profit = option::some(t::usd(100_040));
    d.size = t::mbtc(100);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    let (summary, _) = exec(&mut sc, &fx, ticket, &d);
    assert!(summary.base_filled_ask() == base(100));
    // With flat TWAPs the mark is the median of index, index and book: 100,000 now that the
    // sale moved the best bid to 99,800. A take profit at 100,000 fires on it.
    let mut d = default_sltp();
    d.trigger = MARK;
    d.stop_loss = option::none();
    d.take_profit = option::some(t::usd(100_000));
    d.size = t::mbtc(100);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    let (summary, _) = exec(&mut sc, &fx, ticket, &d);
    assert!(summary.base_filled_ask() == base(100));
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6207, location = perpetuals_orders::stop_orders)]
fun trigger_type_must_be_known() {
    let (mut sc, fx) = os::setup();
    long_setup(&mut sc, &fx);
    let mut d = default_sltp();
    d.trigger = 3;
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

// === Commitment, executor, expiry ===

#[test, expected_failure(abort_code = 6202, location = perpetuals_orders::stop_orders)]
fun revealed_details_must_match_the_commitment() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    let mut revealed = d;
    revealed.salt = b"other";
    exec(&mut sc, &fx, ticket, &revealed);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6204, location = perpetuals_orders::stop_orders)]
fun only_listed_executors_may_execute() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    sc.next_tx(@0xBEEF);
    let executor = ch::no_domain_executor(sc.ctx());
    run_sltp(&mut sc, &fx, t::taker(), ticket, &d, @0xBEEF, &executor);
    t::finish(sc, fx);
}

#[test]
fun a_domain_ticket_needs_a_domain_executor() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    sc.next_tx(t::admin(&fx));
    let domain_uid = object::new(sc.ctx());
    let domain = domain_uid.to_address();
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::some(domain), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    sc.next_tx(t::admin(&fx));
    let executor = ch::domain_executor(&domain_uid, sc.ctx());
    assert!(executor.executor_domain() == option::some(domain));
    let (summary, _) = run_sltp(&mut sc, &fx, t::taker(), ticket, &d, t::admin(&fx), &executor);
    assert!(summary.base_filled_ask() == base(250));
    domain_uid.delete();
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6204, location = perpetuals_orders::stop_orders)]
fun a_domain_ticket_refuses_a_plain_executor() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::some(@0xD0), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6200, location = perpetuals_orders::stop_orders)]
fun expired_tickets_cannot_execute() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let mut d = default_sltp();
    d.expire = option::some(t::clock(&fx).timestamp_ms() + 50);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6208, location = perpetuals_orders::stop_orders)]
fun a_standalone_ticket_cannot_run_as_sltp() {
    let (mut sc, mut fx) = os::setup();
    long_setup(&mut sc, &fx);
    let d = default_sltp();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), STANDALONE, sltp_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 94_000, 100);
    exec(&mut sc, &fx, ticket, &d);
    t::finish(sc, fx);
}

// === Ticket lifecycle ===

#[test, expected_failure(abort_code = 6203, location = perpetuals_orders::stop_orders)]
fun tickets_need_the_minimum_gas() {
    let (mut sc, fx) = os::setup();
    create_ticket(&mut sc, &fx, t::taker(), SLTP, b"x", option::none(), GAS - 1);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6205, location = perpetuals_orders::stop_orders)]
fun ticket_type_must_be_known() {
    let (mut sc, fx) = os::setup();
    create_ticket(&mut sc, &fx, t::taker(), 2, b"x", option::none(), GAS);
    t::finish(sc, fx);
}

#[test]
fun users_and_executors_cancel_tickets_and_recover_the_gas() {
    let (mut sc, fx) = os::setup();
    let first = create_ticket(&mut sc, &fx, t::taker(), SLTP, b"a", option::none(), GAS);
    let second = create_ticket(&mut sc, &fx, t::taker(), SLTP, b"b", option::none(), GAS + 5);
    sc.next_tx(t::admin(&fx));
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    // Edits are allowed on a live ticket.
    stop_orders::edit_stop_order_ticket_details(&mut account, t::cap(&fx, t::taker()), &registry, first, b"c");
    stop_orders::edit_stop_order_ticket_executors(&mut account, t::cap(&fx, t::taker()), &registry, first, vector[@0x1]);
    let gas = stop_orders::cancel(&mut account, t::cap(&fx, t::taker()), &registry, first, sc.ctx());
    assert!(gas.value() == GAS && !account.has_order_ticket(first));
    coin::burn_for_testing(gas);
    let executor = ch::no_domain_executor(sc.ctx());
    let gas = stop_orders::cancel_stop_order_ticket(&mut account, &registry, second, &executor, sc.ctx());
    assert!(gas.value() == GAS + 5 && !account.has_order_ticket(second));
    coin::burn_for_testing(gas);
    ts::return_shared(account);
    ts::return_shared(registry);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 4000, location = perpetuals::account)]
fun another_accounts_cap_cannot_cancel_a_ticket() {
    let (mut sc, fx) = os::setup();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, b"a", option::none(), GAS);
    sc.next_tx(t::admin(&fx));
    let mut account = sc.take_shared_by_id<perpetuals::account::Account<TUSD>>(t::account_obj(&fx, t::taker()));
    let registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let gas = stop_orders::cancel(&mut account, t::cap(&fx, t::maker()), &registry, ticket, sc.ctx());
    coin::burn_for_testing(gas);
    ts::return_shared(account);
    ts::return_shared(registry);
    t::finish(sc, fx);
}

// === Standalone stop orders ===

#[test]
fun standalone_buy_stop_fires_above_the_level() {
    let (mut sc, mut fx) = os::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let d = default_standalone();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), STANDALONE, standalone_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 102_000, 100);
    let (summary, paid) = run_standalone(&mut sc, &fx, t::taker(), ticket, &d);
    assert!(summary.base_filled_bid() == base(100) && paid == GAS);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, base, _, _, _, _) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(base == base(100));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6201, location = perpetuals_orders::stop_orders)]
fun standalone_buy_stop_waits_below_the_level() {
    let (mut sc, fx) = os::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let d = default_standalone();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), STANDALONE, standalone_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    run_standalone(&mut sc, &fx, t::taker(), ticket, &d);
    t::finish(sc, fx);
}

#[test]
fun standalone_sell_stop_rests_a_limit_order_below_the_level() {
    let (mut sc, mut fx) = os::setup();
    t::ladder(&mut sc, &fx, 100_000);
    // Sell 0.1 at 101,000 (above the bids, so it rests) once the index is at or below 99,000.
    let mut d = default_standalone();
    d.is_limit = true;
    d.stop_index_price = t::usd(99_000);
    d.ge = false;
    d.side = ASK;
    d.price = t::px(101_000);
    let ticket = create_ticket(&mut sc, &fx, t::taker(), STANDALONE, standalone_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 98_000, 100);
    let (summary, _) = run_standalone(&mut sc, &fx, t::taker(), ticket, &d);
    assert!(summary.posted_orders() == 1 && summary.base_filled_ask() == 0);
    with_ch!(&mut sc, &fx, |ch| {
        let (_, _, _, asks, _, pending) = t::position_of(ch, t::account_id(&fx, t::taker()));
        assert!(asks == base(100) && pending == 1);
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 6208, location = perpetuals_orders::stop_orders)]
fun an_sltp_ticket_cannot_run_standalone() {
    let (mut sc, mut fx) = os::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let d = default_standalone();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), SLTP, standalone_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 102_000, 100);
    run_standalone(&mut sc, &fx, t::taker(), ticket, &d);
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 32, location = perpetuals::clearing_house)]
fun stop_orders_do_not_run_on_a_paused_market() {
    let (mut sc, mut fx) = os::setup();
    t::ladder(&mut sc, &fx, 100_000);
    let d = default_standalone();
    let ticket = create_ticket(&mut sc, &fx, t::taker(), STANDALONE, standalone_commitment(t::ch_id(&fx), &d), option::none(), GAS);
    t::set_price(&mut sc, &mut fx, 102_000, 100);
    sc.next_tx(t::admin(&fx));
    let mut registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let cap = registry.create_package_pause_guardian_cap(t::perp_admin(&fx), sc.ctx());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(&fx));
    clearing_house.admin_pause_market(&cap, &registry, 1);
    ts::return_shared(clearing_house);
    ts::return_shared(registry);
    transfer::public_transfer(cap, @0x0);
    run_standalone(&mut sc, &fx, t::taker(), ticket, &d);
    t::finish(sc, fx);
}
