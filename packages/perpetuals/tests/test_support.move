// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Test fixture: a vendor registered with the vendor, oracle and perpetuals packages, a mock
/// oracle source feeding a BTC/USD and a TUSD/USD storage, one BTC/USD clearing house with the
/// localnet suite's parameters, and three funded accounts with a position each.
///
/// Amounts: base sizes and order prices carry 9 decimals, TUSD carries 6, ifixed values 18.
#[test_only]
module perpetuals::test_support;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::clock::{Self, Clock};
use haneul::coin::{Self, CoinMetadata, TreasuryCap};
use haneul::test_scenario::{Self as ts, Scenario};
use haneul::test_utils;
use oracle_aggregator::config::Config as OracleConfig;
use oracle_aggregator::init as oracle_init;
use oracle_aggregator::price_feed_storage::{Self as pfs, PriceFeedStorage};
use oracle_aggregator::source::{Self, Source};
use perpetuals::account::{Self, Account};
use perpetuals::authority::{ACCOUNT, PACKAGE, VENDOR};
use perpetuals::clearing_house::{Self as ch, ClearingHouse, SessionHotPotato, SessionSummary};
use perpetuals::init as perp_init;
use perpetuals::market;
use perpetuals::registry::{Self, Registry};
use perpetuals::tusd::TUSD;
use vendor::config::{Self as vendor_config, Config as VendorConfig};
use vendor::init as vendor_init;
use vendor::metadata::{Self, VendorMetadata};

// === Market parameters (the localnet suite's) ===

public struct VK has drop {}

public struct MOCK has drop {}

const ONE: u256 = 1_000_000_000_000_000_000;
const B9: u64 = 1_000_000_000;
const TUSD_UNIT: u64 = 1_000_000;
/// ifixed units per TUSD unit.
const FIXED_PER_TUSD: u256 = 1_000_000_000_000;

const IMR: u256 = 100_000_000_000_000_000; // 10%
const MMR: u256 = 50_000_000_000_000_000; // 5%
const MAKER_FEE: u256 = 200_000_000_000_000; // 0.02%
const TAKER_FEE: u256 = 500_000_000_000_000; // 0.05%
const LIQ_FEE: u256 = 10_000_000_000_000_000; // 1%
const IF_FEE: u256 = 5_000_000_000_000_000; // 0.5%
const LOT: u64 = 1_000_000; // 0.001 BTC
const TICK: u64 = 1_000_000_000; // $1
const BTC0: u64 = 100_000; // initial BTC price in dollars
const START_MS: u64 = 1_000_000_000;

public fun one(): u256 { ONE }
public fun b9(): u64 { B9 }
public fun tusd_unit(): u64 { TUSD_UNIT }
public fun fixed_per_tusd(): u256 { FIXED_PER_TUSD }
public fun imr(): u256 { IMR }
public fun mmr(): u256 { MMR }
public fun maker_fee(): u256 { MAKER_FEE }
public fun taker_fee(): u256 { TAKER_FEE }
public fun liq_fee(): u256 { LIQ_FEE }
public fun if_fee(): u256 { IF_FEE }
public fun lot(): u64 { LOT }
public fun tick(): u64 { TICK }
public fun btc0(): u64 { BTC0 }

/// Dollars to a 9-decimal order price.
public fun px(dollars: u64): u64 { dollars * B9 }
/// BTC thousandths to a 9-decimal size.
public fun mbtc(thousandths: u64): u64 { thousandths * LOT }
/// Dollars to an ifixed value.
public fun usd(dollars: u64): u256 { (dollars as u256) * ONE }
/// TUSD units to an ifixed collateral value.
public fun col(tusd_units: u64): u256 { (tusd_units as u256) * FIXED_PER_TUSD }

// === Fixture ===

/// Account indices.
const MAKER: u64 = 0;
const TAKER: u64 = 1;
const LIQUIDATOR: u64 = 2;
public fun maker(): u64 { MAKER }
public fun taker(): u64 { TAKER }
public fun liquidator(): u64 { LIQUIDATOR }

public struct Acct has store {
    account_id: u64,
    obj: ID,
    cap: AuthorityCap<ACCOUNT, ADMIN>,
}

public struct Fx {
    admin: address,
    clock: Clock,
    vendor_cap: AuthorityCap<vendor::authority::VENDOR<VK>, ADMIN>,
    oracle_admin: AuthorityCap<oracle_aggregator::authority::PACKAGE, ADMIN>,
    oracle_vk: AuthorityCap<oracle_aggregator::authority::VENDOR<VK>, ADMIN>,
    perp_admin: AuthorityCap<PACKAGE, ADMIN>,
    perp_vk: AuthorityCap<VENDOR<VK>, ADMIN>,
    source: Source<MOCK>,
    metadata: VendorMetadata<VK>,
    treasury: TreasuryCap<TUSD>,
    coin_metadata: CoinMetadata<TUSD>,
    registry: ID,
    pfs_btc: ID,
    pfs_tusd: ID,
    ch: ID,
    accounts: vector<Acct>,
}

public fun admin(fx: &Fx): address { fx.admin }
public fun clock(fx: &Fx): &Clock { &fx.clock }
public fun clock_mut(fx: &mut Fx): &mut Clock { &mut fx.clock }
public fun perp_vk(fx: &Fx): &AuthorityCap<VENDOR<VK>, ADMIN> { &fx.perp_vk }
public fun perp_admin(fx: &Fx): &AuthorityCap<PACKAGE, ADMIN> { &fx.perp_admin }
public fun ch_id(fx: &Fx): ID { fx.ch }
public fun registry_id(fx: &Fx): ID { fx.registry }
public fun pfs_btc_id(fx: &Fx): ID { fx.pfs_btc }
public fun pfs_tusd_id(fx: &Fx): ID { fx.pfs_tusd }
public fun account_id(fx: &Fx, who: u64): u64 { fx.accounts[who].account_id }
public fun account_obj(fx: &Fx, who: u64): ID { fx.accounts[who].obj }
public fun cap(fx: &Fx, who: u64): &AuthorityCap<ACCOUNT, ADMIN> { &fx.accounts[who].cap }
public fun coin_metadata(fx: &Fx): &CoinMetadata<TUSD> { &fx.coin_metadata }

/// Initial TUSD deposits and clearing house allocations per account.
public fun deposits(): vector<u64> { vector[1_000_000, 100_000, 200_000] }
public fun allocations(): vector<u64> { vector[500_000, 20_000, 100_000] }

// `coin::create_currency` is the pre-registry path, kept because it yields the CoinMetadata
// that `create_clearing_house` reads the decimals from.
#[allow(deprecated_usage)]
public fun setup(): (Scenario, Fx) {
    let admin = @0xAD;
    let mut sc = ts::begin(admin);
    vendor_init::init_for_testing(sc.ctx());
    oracle_init::init_for_testing(sc.ctx());
    perp_init::init_for_testing(sc.ctx());
    let (treasury, coin_metadata) = coin::create_currency(
        test_utils::create_one_time_witness<TUSD>(),
        6,
        b"TUSD",
        b"Test USD",
        b"Unit test collateral",
        option::none(),
        sc.ctx(),
    );
    let mut clock = clock::create_for_testing(sc.ctx());
    clock.set_for_testing(START_MS);

    // Vendor registration with the three packages.
    sc.next_tx(admin);
    let vendor_pkg_admin =
        sc.take_from_sender<AuthorityCap<vendor::authority::PACKAGE, ADMIN>>();
    let oracle_admin =
        sc.take_from_sender<AuthorityCap<oracle_aggregator::authority::PACKAGE, ADMIN>>();
    let perp_admin = sc.take_from_sender<AuthorityCap<PACKAGE, ADMIN>>();
    let mut vconfig = sc.take_shared<VendorConfig>();
    let mut oconfig = sc.take_shared<OracleConfig>();
    let mut registry = sc.take_shared<Registry>();
    let vendor_cap = vendor_config::register_vendor_for_testing<VK, ADMIN>(&mut vconfig, &vendor_pkg_admin);
    let mut md = metadata::new<VK, ADMIN>(
        &mut vconfig,
        &vendor_cap,
        b"Unit test vendor".to_ascii_string(),
        b"perpetuals unit tests".to_ascii_string(),
    );
    md.approve_domain_registration<VK, oracle_aggregator::authority::PACKAGE>(&vconfig, &oracle_admin);
    md.approve_domain_registration<VK, PACKAGE>(&vconfig, &perp_admin);
    let oracle_vk = oconfig.register_vendor<VK, ADMIN>(&vendor_cap, &vconfig, &md);
    let perp_vk = registry.register_vendor<VK, ADMIN>(&vendor_cap, &vconfig, &mut md);

    // A mock source feeding two storages, with a 1 ms TWAP so the TWAP tracks the price.
    let mut source = source::create<MOCK, ADMIN>(&mut oconfig, &oracle_admin, &MOCK {}, 1);
    source.set_authorized(&oconfig, &oracle_admin, true);
    let mut pfs_btc = pfs::new<VK, ADMIN>(&mut oconfig, &oracle_vk, b"BTC/USD".to_string());
    let mut pfs_tusd = pfs::new<VK, ADMIN>(&mut oconfig, &oracle_vk, b"TUSD/USD".to_string());
    let source_id = source.source_id();
    pfs_btc.new_price_feed(
        &oracle_vk, &oconfig, source.borrow_source_cap(MOCK {}), &source,
        ((BTC0 as u256) * ONE as u128), clock.timestamp_ms(), 1,
    );
    pfs_tusd.new_price_feed(
        &oracle_vk, &oconfig, source.borrow_source_cap(MOCK {}), &source,
        (ONE as u128), clock.timestamp_ms(), 1,
    );

    // The clearing house.
    let orderbook = ch::create_orderbook(&perp_vk, &registry, 2, 4, 4, 2, 3, 4, sc.ctx());
    // No socialization: bad debt beyond the insurance fund is left to ADL.
    let mut params = market::new_creation_params(IMR, MMR, LOT, TICK, 0, 0);
    params.set_fees(MAKER_FEE, TAKER_FEE, LIQ_FEE, IF_FEE);
    params.set_funding(60_000, 21_600_000);
    params.set_premium_twap(1_000, 60_000);
    params.set_spread_twap(1_000, 60_000);
    params.set_priority_taker_fee(option::some(1_000_000_000_000_000));
    let clearing_house = ch::create_clearing_house<TUSD, VK, ADMIN>(
        orderbook, &perp_vk, &mut registry, &coin_metadata, &clock, &pfs_btc, &pfs_tusd,
        source_id, source_id, &params, sc.ctx(),
    );
    ch::register_market<VK, ADMIN, TUSD>(&mut registry, &perp_vk, &clearing_house);
    let ch_id = object::id(&clearing_house);
    let (pfs_btc_id, pfs_tusd_id) = (object::id(&pfs_btc), object::id(&pfs_tusd));
    let registry_id = object::id(&registry);
    ch::share(clearing_house);
    transfer::public_share_object(pfs_btc);
    transfer::public_share_object(pfs_tusd);
    ts::return_shared(vconfig);
    ts::return_shared(oconfig);
    ts::return_shared(registry);
    sc.return_to_sender(vendor_pkg_admin);

    // Accounts: deposit, then create a position, allocate and opt into full leverage.
    sc.next_tx(admin);
    let mut registry = sc.take_shared<Registry>();
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(ch_id);
    let mut accounts = vector[];
    let (deposits, allocations) = (deposits(), allocations());
    let mut i = 0;
    while (i < deposits.length()) {
        let (mut acc, policy, cap) = account::create_account<TUSD>(&mut registry, sc.ctx());
        let coin = coin::mint_for_testing<TUSD>(deposits[i] * TUSD_UNIT, sc.ctx());
        acc.deposit_collateral(&cap, &registry, coin);
        clearing_house.create_market_position(&cap, &acc);
        clearing_house.allocate_collateral(&cap, &mut acc, allocations[i] * TUSD_UNIT);
        clearing_house.set_position_initial_margin_ratio(&cap, &acc, IMR);
        accounts.push_back(Acct { account_id: acc.account_id(), obj: object::id(&acc), cap });
        account::consume_policy_and_share_account(acc, policy);
        i = i + 1;
    };
    ts::return_shared(registry);
    ts::return_shared(clearing_house);

    let fx = Fx {
        admin, clock, vendor_cap, oracle_admin, oracle_vk, perp_admin, perp_vk, source,
        metadata: md, treasury, coin_metadata,
        registry: registry_id, pfs_btc: pfs_btc_id, pfs_tusd: pfs_tusd_id, ch: ch_id, accounts,
    };
    (sc, fx)
}

public fun finish(sc: Scenario, fx: Fx) {
    let Fx {
        admin: _, clock, vendor_cap, oracle_admin, oracle_vk, perp_admin, perp_vk, source,
        metadata, treasury, coin_metadata, registry: _, pfs_btc: _, pfs_tusd: _, ch: _,
        mut accounts,
    } = fx;
    clock.destroy_for_testing();
    transfer::public_transfer(vendor_cap, @0x0);
    transfer::public_transfer(oracle_admin, @0x0);
    transfer::public_transfer(oracle_vk, @0x0);
    transfer::public_transfer(perp_admin, @0x0);
    transfer::public_transfer(perp_vk, @0x0);
    transfer::public_transfer(source, @0x0);
    transfer::public_transfer(metadata, @0x0);
    transfer::public_transfer(treasury, @0x0);
    transfer::public_transfer(coin_metadata, @0x0);
    while (!accounts.is_empty()) {
        let Acct { account_id: _, obj: _, cap } = accounts.pop_back();
        transfer::public_transfer(cap, @0x0);
    };
    accounts.destroy_empty();
    sc.end();
}

// === Steps ===

/// Advances the clock by `ms` and pushes the BTC price (in dollars) and a TUSD price of 1.
public fun set_price(sc: &mut Scenario, fx: &mut Fx, btc_dollars: u64, ms: u64) {
    sc.next_tx(fx.admin);
    fx.clock.increment_for_testing(ms);
    let oconfig = sc.take_shared<OracleConfig>();
    let mut pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_btc);
    let mut pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_tusd);
    let now = fx.clock.timestamp_ms();
    pfs_btc.update_price_feed(
        &oconfig, fx.source.borrow_source_cap(MOCK {}), &fx.source,
        ((btc_dollars as u256) * ONE as u128), now,
    );
    pfs_tusd.update_price_feed(
        &oconfig, fx.source.borrow_source_cap(MOCK {}), &fx.source, (ONE as u128), now,
    );
    ts::return_shared(oconfig);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
}

/// Runs a trading session for account `who`: the closure receives the session hot potato.
public macro fun session(
    $sc: &mut Scenario,
    $fx: &Fx,
    $who: u64,
    $allocate_missing_margin: bool,
    $deallocate_free_collateral: bool,
    $f: |&mut SessionHotPotato<TUSD>|,
): SessionSummary {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin());
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj($who));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_btc_id());
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_tusd_id());
    let cap = fx.cap($who);
    let mut hp = clearing_house.start_session(
        cap, &mut account, &pfs_btc, &pfs_tusd, option::none(), fx.clock(), sc.ctx(),
    );
    $f(&mut hp);
    let (clearing_house, summary) =
        hp.end_session(cap, &mut account, $allocate_missing_margin, $deallocate_free_collateral);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    summary
}

/// Reads state through the shared clearing house.
public macro fun with_ch($sc: &mut Scenario, $fx: &Fx, $f: |&mut ClearingHouse<TUSD>|) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    $f(&mut clearing_house);
    ts::return_shared(clearing_house);
}

/// Reads or edits an account.
public macro fun with_account($sc: &mut Scenario, $fx: &Fx, $who: u64, $f: |&mut Account<TUSD>|) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj($who));
    $f(&mut account);
    ts::return_shared(account);
}

/// Runs `$f` with the clearing house, the account, both oracles and the registry, for the entry
/// points outside a session (deallocation, cancels, admin actions).
public macro fun with_market(
    $sc: &mut Scenario,
    $fx: &Fx,
    $who: u64,
    $f: |&mut ClearingHouse<TUSD>, &mut Account<TUSD>, &PriceFeedStorage, &PriceFeedStorage, &mut Registry|,
) {
    let (sc, fx) = ($sc, $fx);
    sc.next_tx(fx.admin());
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(fx.ch_id());
    let mut account = sc.take_shared_by_id<Account<TUSD>>(fx.account_obj($who));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_btc_id());
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(fx.pfs_tusd_id());
    let mut registry = sc.take_shared_by_id<Registry>(fx.registry_id());
    $f(&mut clearing_house, &mut account, &pfs_btc, &pfs_tusd, &mut registry);
    ts::return_shared(clearing_house);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    ts::return_shared(registry);
}

/// The maker rests three ask levels and three bid levels of 0.1 BTC around `mid` dollars.
public fun ladder(sc: &mut Scenario, fx: &Fx, mid: u64) {
    session!(sc, fx, MAKER, false, false, |hp| {
        hp.place_limit_order(true, mbtc(100), px(mid), 0, option::none(), false, option::none());
        hp.place_limit_order(true, mbtc(100), px(mid + 100), 0, option::none(), false, option::none());
        hp.place_limit_order(true, mbtc(100), px(mid + 200), 0, option::none(), false, option::none());
        hp.place_limit_order(false, mbtc(100), px(mid - 100), 0, option::none(), false, option::none());
        hp.place_limit_order(false, mbtc(100), px(mid - 200), 0, option::none(), false, option::none());
        hp.place_limit_order(false, mbtc(100), px(mid - 300), 0, option::none(), false, option::none());
    });
}

/// Position snapshot: (collateral, base, quote, pending asks, pending bids, pending orders).
public fun position_of(clearing_house: &ClearingHouse<TUSD>, account_id: u64): (u256, u256, u256, u256, u256, u64) {
    let p = clearing_house.position(account_id);
    let (base, quote) = p.base_and_quote_amounts();
    let (asks, bids) = p.pending_base_amounts_by_side();
    (p.collateral(), base, quote, asks, bids, p.pending_order_count())
}
