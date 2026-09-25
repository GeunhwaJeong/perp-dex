// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Vault fixture on top of the perpetuals fixture: the vault package initialized, a test coin
/// registry, a VLP currency, and one vault over the fixture's BTC/USD market with 1 TUSD of
/// owner-locked liquidity. Helpers deposit, trade through the vault and run withdrawals.
///
/// Every vault entry point that takes the vault or its account by value shares them again on
/// its way out, so the helpers take the shared objects and let the package re-share them.
#[test_only]
module market_making_vault::vault_test_support;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::coin::{Self, Coin, CoinMetadata};
use haneul::coin_registry::{Self, CoinRegistry};
use haneul::test_scenario::{Self as ts, Scenario};
use haneul::test_utils;
use market_making_vault::authority::{PACKAGE, TREASURY, VAULT};
use market_making_vault::config::Config;
use market_making_vault::init as vault_init;
use market_making_vault::interface;
use market_making_vault::vault::{Vault, UserLpCoin};
use market_making_vault::vlp::VLP;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::Account;
use perpetuals::clearing_house::ClearingHouse;
use perpetuals::registry::Registry;
use perpetuals::test_support::{Self as t, Fx};
use perpetuals::tusd::TUSD;

const LOCK_MS: u64 = 20_000;
const FORCE_DELAY_MS: u64 = 10_000;
const OWNER_FEE: u256 = 100_000_000_000_000_000; // 10%

public fun lock_ms(): u64 { LOCK_MS }
public fun force_delay_ms(): u64 { FORCE_DELAY_MS }
public fun owner_fee(): u256 { OWNER_FEE }

public struct VFx {
    vault: ID,
    account: ID,
    admin_cap: AuthorityCap<VAULT<VLP>, ADMIN>,
    treasury_cap: AuthorityCap<VAULT<VLP>, TREASURY>,
    package_admin: AuthorityCap<PACKAGE, ADMIN>,
    vlp_metadata: CoinMetadata<VLP>,
}

public fun vault_id(v: &VFx): ID { v.vault }
public fun account_id(v: &VFx): ID { v.account }
public fun admin_cap(v: &VFx): &AuthorityCap<VAULT<VLP>, ADMIN> { &v.admin_cap }
public fun treasury_cap(v: &VFx): &AuthorityCap<VAULT<VLP>, TREASURY> { &v.treasury_cap }
public fun package_admin(v: &VFx): &AuthorityCap<PACKAGE, ADMIN> { &v.package_admin }

/// The perpetuals fixture plus a vault created by its admin with 1 TUSD locked.
#[allow(deprecated_usage)]
public fun setup(): (Scenario, Fx, VFx) {
    let (mut sc, fx) = t::setup();
    let admin = t::admin(&fx);
    sc.next_tx(admin);
    vault_init::init_for_testing(sc.ctx());
    sc.next_tx(admin);
    let package_admin = sc.take_from_sender<AuthorityCap<PACKAGE, ADMIN>>();
    // The coin registry can only be created by the system address.
    sc.next_tx(@0x0);
    let registry = coin_registry::create_coin_data_registry_for_testing(sc.ctx());
    coin_registry::share_for_testing(registry);

    sc.next_tx(admin);
    let (vlp_treasury, vlp_metadata) = coin::create_currency(
        test_utils::create_one_time_witness<VLP>(), 6, b"VLP", b"Vault LP", b"", option::none(), sc.ctx(),
    );
    let mut perps_registry = sc.take_shared_by_id<Registry>(t::registry_id(&fx));
    let mut config = sc.take_shared<Config>();
    let mut coin_reg = sc.take_shared<CoinRegistry>();
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(&fx));
    interface::create_vault<VLP, TUSD>(
        &mut perps_registry, &mut config, vlp_treasury, &mut coin_reg, &vlp_metadata,
        t::coin_metadata(&fx), &pfs_tusd, LOCK_MS, OWNER_FEE, FORCE_DELAY_MS,
        coin::mint_for_testing<TUSD>(t::tusd_unit(), sc.ctx()),
        b"Unit test vault".to_ascii_string(), b"".to_ascii_string(),
        option::none(), option::none(), option::none(), option::none(), option::none(),
        t::clock(&fx), sc.ctx(),
    );
    ts::return_shared(perps_registry);
    ts::return_shared(config);
    ts::return_shared(coin_reg);
    ts::return_shared(pfs_tusd);

    sc.next_tx(admin);
    let admin_cap = sc.take_from_sender<AuthorityCap<VAULT<VLP>, ADMIN>>();
    let treasury_cap = sc.take_from_sender<AuthorityCap<VAULT<VLP>, TREASURY>>();
    let vault = ts::most_recent_id_shared<Vault<VLP, TUSD>>().destroy_some();
    let account = ts::most_recent_id_shared<Account<TUSD>>().destroy_some();
    (sc, fx, VFx { vault, account, admin_cap, treasury_cap, package_admin, vlp_metadata })
}

public fun finish(sc: Scenario, fx: Fx, v: VFx) {
    let VFx { vault: _, account: _, admin_cap, treasury_cap, package_admin, vlp_metadata } = v;
    transfer::public_transfer(admin_cap, @0x0);
    transfer::public_transfer(package_admin, @0x0);
    transfer::public_transfer(treasury_cap, @0x0);
    transfer::public_transfer(vlp_metadata, @0x0);
    t::finish(sc, fx);
}

/// `who` deposits `units` of TUSD, valuing the fixture's market on the way, and receives LP.
public fun deposit(sc: &mut Scenario, fx: &Fx, v: &VFx, who: address, units: u64): UserLpCoin<VLP> {
    let listed = ch_in_vault(sc, v, fx);
    sc.next_tx(who);
    let vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let mut config = sc.take_shared<Config>();
    let perps_registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let coin = coin::mint_for_testing<TUSD>(units, sc.ctx());
    let mut session = interface::start_deposit_session(vault, &config, account, &pfs_tusd, coin, t::clock(fx), sc.ctx());
    if (listed) {
        let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
        interface::process_clearing_house_for_deposit(&mut session, clearing_house, &pfs_btc, t::clock(fx));
    };
    let lp = interface::end_deposit_session(session, &mut config, 0, &perps_registry, sc.ctx());
    ts::return_shared(config);
    ts::return_shared(perps_registry);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    lp
}

/// Whether the fixture's market is in the vault's list.
public fun ch_in_vault(sc: &mut Scenario, v: &VFx, fx: &Fx): bool {
    // Objects returned in the previous step only become takeable after a new transaction.
    sc.next_tx(t::admin(fx));
    let vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let listed = vault_ch_ids(&vault).contains(&t::ch_id(fx));
    ts::return_shared(vault);
    listed
}

public fun vault_ch_ids(vault: &Vault<VLP, TUSD>): vector<ID> {
    market_making_vault::vault::ch_ids(vault)
}

/// Reads the vault: (LP supply, vault account idle collateral, owner fees).
public fun vault_state(sc: &mut Scenario, v: &VFx): (u64, u64, u64) {
    sc.next_tx(@0xAD);
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let supply = vault.lp_supply_value();
    let idle = account.collateral_balance();
    let fees = market_making_vault::vault::owner_fees_mut(&mut vault).value();
    ts::return_shared(vault);
    ts::return_shared(account);
    (supply, idle, fees)
}

/// The vault opens a position in the fixture's market, allocates `alloc_units` and opts into the
/// market's leverage.
public fun vault_enters_market(sc: &mut Scenario, fx: &Fx, v: &VFx, alloc_units: u64) {
    sc.next_tx(t::admin(fx));
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let mut account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let mut clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    interface::create_market_position(&vault, &v.admin_cap, &account, &mut clearing_house);
    interface::set_position_initial_margin_ratio(&vault, &v.admin_cap, &account, &mut clearing_house, t::imr());
    interface::allocate_collateral_to_position(&mut vault, &v.admin_cap, &mut account, &mut clearing_house, alloc_units, t::clock(fx));
    ts::return_shared(vault);
    ts::return_shared(account);
    ts::return_shared(clearing_house);
}

/// The vault takes a market order in the fixture's market.
public fun vault_market_order(sc: &mut Scenario, fx: &Fx, v: &VFx, side: bool, size: u64, reduce_only: bool) {
    sc.next_tx(t::admin(fx));
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let mut account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let clearing_house = interface::place_market_order(
        &mut vault, &v.admin_cap, &mut account, clearing_house, &pfs_btc, &pfs_tusd, side, size,
        reduce_only, option::none(), t::clock(fx), sc.ctx(),
    );
    ts::return_shared(clearing_house);
    ts::return_shared(vault);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
}

/// The vault rests a limit order in the fixture's market; returns its id.
public fun vault_limit_order(sc: &mut Scenario, fx: &Fx, v: &VFx, side: bool, size: u64, price: u64): u128 {
    sc.next_tx(t::admin(fx));
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let mut account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let (clearing_house, id) = interface::place_limit_order(
        &mut vault, &v.admin_cap, &mut account, clearing_house, &pfs_btc, &pfs_tusd, side, size,
        price, 0, option::none(), false, option::none(), option::none(), t::clock(fx), sc.ctx(),
    );
    ts::return_shared(clearing_house);
    ts::return_shared(vault);
    ts::return_shared(account);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    id.destroy_some()
}

/// `who` files a withdraw request for `lp_amount` of their coin.
public fun request_withdraw(sc: &mut Scenario, fx: &Fx, v: &VFx, who: address, lp: UserLpCoin<VLP>, lp_amount: u64, min_out: u64) {
    sc.next_tx(who);
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let mut config = sc.take_shared<Config>();
    interface::create_withdraw_request(&mut vault, &mut config, lp, lp_amount, min_out, t::clock(fx), sc.ctx());
    ts::return_shared(vault);
    ts::return_shared(config);
}

/// `who` force-withdraws their matured request, closing `size_to_close` of the vault's position
/// in the fixture's market (with `order_ids` canceled first) if the market is in the vault.
/// Returns the collateral paid out.
public fun force_withdraw(sc: &mut Scenario, fx: &Fx, v: &VFx, who: address, size_to_close: u64, order_ids: vector<u128>): u64 {
    let listed = ch_in_vault(sc, v, fx);
    sc.next_tx(who);
    let vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let mut config = sc.take_shared<Config>();
    let perps_registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let mut session = interface::start_force_withdraw_session(vault, account, &pfs_tusd, t::clock(fx), sc.ctx());
    if (listed) {
        let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
        interface::process_clearing_house_for_force_withdraw(
            &mut session, clearing_house, &pfs_btc, &pfs_tusd, size_to_close, &order_ids,
            option::none(), t::clock(fx), sc.ctx(),
        );
    };
    let out: Coin<TUSD> = interface::end_withdraw_session(session, &mut config, &perps_registry, sc.ctx());
    let amount = out.value();
    coin::burn_for_testing(out);
    ts::return_shared(config);
    ts::return_shared(perps_registry);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    amount
}

/// Yield (collateral) added straight to the vault's account raises every LP's value.
public fun add_yield(sc: &mut Scenario, fx: &Fx, v: &VFx, units: u64) {
    sc.next_tx(t::admin(fx));
    let vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let mut account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let perps_registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    interface::add_yield(&vault, &mut account, &perps_registry, coin::mint_for_testing<TUSD>(units, sc.ctx()));
    ts::return_shared(vault);
    ts::return_shared(account);
    ts::return_shared(perps_registry);
}

/// The owner processes `target`'s withdraw request, valuing the fixture's market if listed.
/// Returns the collateral paid out.
public fun owner_process_withdraw(sc: &mut Scenario, fx: &Fx, v: &VFx, target: address): u64 {
    let listed = ch_in_vault(sc, v, fx);
    sc.next_tx(t::admin(fx));
    let vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let mut config = sc.take_shared<Config>();
    let perps_registry = sc.take_shared_by_id<Registry>(t::registry_id(fx));
    let pfs_btc = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_btc_id(fx));
    let pfs_tusd = sc.take_shared_by_id<PriceFeedStorage>(t::pfs_tusd_id(fx));
    let mut session = interface::start_owner_process_withdraw_request(
        vault, &v.admin_cap, account, &pfs_tusd, target, t::clock(fx),
    );
    if (listed) {
        let clearing_house = sc.take_shared_by_id<ClearingHouse<TUSD>>(t::ch_id(fx));
        interface::process_clearing_house_for_withdraw(&mut session, &v.admin_cap, clearing_house, &pfs_btc, t::clock(fx));
    };
    // Paid to the requester.
    interface::end_withdraw_session_and_transfer_to_recipient(session, &mut config, &perps_registry, sc.ctx());
    ts::return_shared(config);
    ts::return_shared(perps_registry);
    ts::return_shared(pfs_btc);
    ts::return_shared(pfs_tusd);
    sc.next_tx(target);
    let paid = sc.take_from_sender<Coin<TUSD>>();
    let amount = paid.value();
    coin::burn_for_testing(paid);
    amount
}

/// `who` (holder of a matured request) pauses the vault's trading for the force-withdraw window.
public fun pause_for_force_withdraw(sc: &mut Scenario, fx: &Fx, v: &VFx, who: address) {
    sc.next_tx(who);
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    let config = sc.take_shared<Config>();
    interface::pause_vault_for_force_withdraw(&mut vault, &config, t::clock(fx), sc.ctx());
    ts::return_shared(vault);
    ts::return_shared(config);
}

public fun resume_after_force_withdraw_pause(sc: &mut Scenario, fx: &Fx, v: &VFx) {
    sc.next_tx(t::admin(fx));
    let mut vault = sc.take_shared_by_id<Vault<VLP, TUSD>>(v.vault);
    interface::resume_vault_for_force_withdraw(&mut vault, t::clock(fx));
    ts::return_shared(vault);
}

/// Advances time by `ms` with both feeds kept fresh at an unchanged price.
public fun wait(sc: &mut Scenario, fx: &mut Fx, ms: u64) {
    t::set_price(sc, fx, 100_000, ms);
}

/// The perpetuals account id the vault trades under.
public fun vault_account_id(sc: &mut Scenario, v: &VFx): u64 {
    sc.next_tx(@0xAD);
    let account = sc.take_shared_by_id<Account<TUSD>>(v.account);
    let id = account.account_id();
    ts::return_shared(account);
    id
}
