// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::clearing_house;

use authority_cap::authority::{ADMIN, ASSISTANT, AuthorityCap};
use haneul::balance::{Self, Balance};
use haneul::clock::Clock;
use haneul::coin::{Self, Coin, CoinMetadata};
use haneul::coin_registry::Currency;
use haneul::dynamic_field as df;
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::account::{Account, IntegratorInfo};
use perpetuals::authority::{
    ACCOUNT,
    FREEZE_GUARDIAN,
    MAINTENANCE,
    PACKAGE,
    PAUSE_GUARDIAN,
    TREASURY,
    VENDOR,
};
use perpetuals::events::{Self, FilledMakerOrder};
use perpetuals::keys;
use perpetuals::market::{Self, MarketCreationParams, MarketParams, MarketState};
use perpetuals::orderbook::{Self, Order, Orderbook};
use perpetuals::registry::Registry;
use position::position::{Self, Position};
use std::string::String;
use std::type_name;
use std::u64;

// === Errors and constants ===

const EDepositOrWithdrawAmountZero: u64 = 0;
const ESizeOrPositionZero: u64 = 1;
const EInvalidVersionUpgradeValue: u64 = 2;
const EOrderUsdValueTooLow: u64 = 3;
const EInvalidForceCancelIds: u64 = 4;
const ELiquidateNotFirstOperation: u64 = 5;
const EEmptyCancelOrderIds: u64 = 6;
const ESettlementPricesNotSet: u64 = 7;
const ESelfLiquidation: u64 = 8;
const EReduceOnlyViolated: u64 = 9;
const EInvalidVersion: u64 = 10;
const EEmptySession: u64 = 11;
const ESettlementAlreadyEnabled: u64 = 12;
const ENegativeFeesAccrued: u64 = 13;
const EInvalidExpirationTimestamp: u64 = 14;
const EMaxOpenInterestSurpassed: u64 = 15;
const EMaxOpenInterestPositionPercentSurpassed: u64 = 16;
const EPriceFeedSourceDoesNotExist: u64 = 17;
const EWrongAccountIdForAllocation: u64 = 18;
const ESizeNotMultipleOfLotSize: u64 = 19;
const EPriceNotMultipleOfTickSize: u64 = 20;
const ENoOpenInterestToSocializeBadDebt: u64 = 21;
const EBadDebtNotionalAboveThreshold: u64 = 22;
const EInsufficientVaultCollateral: u64 = 23;
const EBadDebtSocializationAboveThreshold: u64 = 24;
const EProposalAlreadyExists: u64 = 25;
const EPrematureProposal: u64 = 26;
const EInvalidProposalDelay: u64 = 27;
const EProposalDoesNotExist: u64 = 28;
const EInsufficientInsuranceSurplus: u64 = 29;
const ENotEnoughCollateralToAllocateForSession: u64 = 30;
const EInsufficientSettlementInsurance: u64 = 31;
const EMarketIsPaused: u64 = 32;
const EMarketIsNotPaused: u64 = 33;
const EMarketIsNotClosed: u64 = 34;
const EMarketIsClosed: u64 = 35;
const ESettlementPricesDisabled: u64 = 36;
const EMaxPendingOrdersExceeded: u64 = 37;
const EPositionAboveMmr: u64 = 38;
const EPositionBadDebt: u64 = 39;
const EInsufficientFreeCollateral: u64 = 40;
const EPositionAlreadyExists: u64 = 41;
const EDeallocateTargetMrTooLow: u64 = 42;
const EInvalidOrderType: u64 = 44;
const ENotEnoughLiquidity: u64 = 45;
const EFillOrKillOrderNotFilled: u64 = 46;
const EPostOnlyOrderWouldMatch: u64 = 47;
const EPendingOrdersNotCanceled: u64 = 48;
const EInvalidSettlementPrices: u64 = 49;
const EInvalidAuthorityCap: u64 = 50;
const ESameSessionOppositeSideTakerFill: u64 = 51;
const ELiquidationRequiresMissingMarginAllocation: u64 = 52;
const EInvalidPauseMode: u64 = 53;
const EStalePendingRepostRequiresInitialMargin: u64 = 54;
const ENotFrozen: u64 = 55;
const EInvalidResumeVersion: u64 = 56;
const EBelowMmrCannotRestOrder: u64 = 57;
const EInvalidOrderPrice: u64 = 3900;

// === Types ===

public struct ClearingHouse<phantom T> has key {
    id: UID,
    version: u64,
    paused: u8,
    market_params: MarketParams,
    market_state: MarketState,
    orderbook: Orderbook,
}

public struct Vault<phantom T> has store {
    collateral_balance: Balance<T>,
    insurance_fund_balance: Balance<T>,
}

public struct MarginRatioProposal has store {
    maturity: u64,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
}

public struct SettlementPrices has store {
    base_price: Option<u256>,
    collateral_price: Option<u256>,
    enabled: bool,
}

public struct Executor has drop { sender: address, domain: Option<address> }

public struct SessionHotPotato<phantom T> {
    clearing_house: ClearingHouse<T>,
    account_id: u64,
    timestamp_ms: u64,
    collateral_price: u256,
    mark_price: u256,
    uses_priority_gas_price: bool,
    margin_before: u256,
    min_margin_before: u256,
    position_base_before: u256,
    total_open_interest: u256,
    total_fees: u256,
    taker_pending_cancelled: bool,
    maker_events: vector<FilledMakerOrder>,
    integrator_info: Option<IntegratorInfo>,
    liqee_account_id: Option<u64>,
    liquidator_fees: u256,
    session_summary: SessionSummary,
}

/// What one liquidation step did to the liqee's position. `margin` and `min_margin` are the
/// position's margin and requirement afterwards at the market's initial margin ratio.
public struct LiquidationOutcome has copy, drop {
    margin: u256,
    min_margin: u256,
    is_long: bool,
    base_liquidated: u256,
    quote_liquidated: u256,
    pnl: u256,
    liquidation_fees: u256,
    insurance_fund_fees: u256,
    bad_debt: u256,
    open_interest_delta: u256,
}

public struct SessionSummary has copy, drop {
    base_filled_ask: u256,
    base_filled_bid: u256,
    quote_filled_ask: u256,
    quote_filled_bid: u256,
    base_posted_ask: u256,
    base_posted_bid: u256,
    posted_orders: u64,
    base_liquidated: u256,
    quote_liquidated: u256,
    is_liqee_long: bool,
    bad_debt: u256,
}

// === Functions ===

public fun version<T>(ch: &ClearingHouse<T>): u64 {
    ch.version
}

public fun is_frozen<T>(clearing_house: &ClearingHouse<T>): bool {
    df::exists_with_type<_, u64>(&clearing_house.id, keys::frozen_version())
}

public fun market_params<T>(ch: &ClearingHouse<T>): &MarketParams {
    &ch.market_params
}

public(package) fun borrow_mut_market_params<T>(ch: &mut ClearingHouse<T>): &mut MarketParams {
    &mut ch.market_params
}

public fun market_state<T>(ch: &ClearingHouse<T>): &MarketState {
    &ch.market_state
}

public(package) fun borrow_mut_market_state<T>(ch: &mut ClearingHouse<T>): &mut MarketState {
    &mut ch.market_state
}

public fun market_pause_mode<T>(ch: &ClearingHouse<T>): u8 {
    ch.paused
}

public fun is_market_paused<T>(ch: &ClearingHouse<T>): bool {
    ch.paused != 0
}

public fun is_market_cancel_only<T>(ch: &ClearingHouse<T>): bool {
    ch.paused == 2
}

public fun market_objects<T>(ch: &ClearingHouse<T>): (&MarketParams, &MarketState) {
    (&ch.market_params, &ch.market_state)
}

public(package) fun borrow_mut_market_objects<T>(
    ch: &mut ClearingHouse<T>,
): (&MarketParams, &mut MarketState) {
    (&ch.market_params, &mut ch.market_state)
}

public(package) fun settlement_prices<T>(ch: &ClearingHouse<T>): &SettlementPrices {
    df::borrow(&ch.id, keys::settlement_prices())
}

public fun settlement_valuation_prices<T>(ch: &ClearingHouse<T>): (bool, u256, u256) {
    if (!df::exists(&ch.id, keys::settlement_prices())) return (false, 0, 0);
    let prices: &SettlementPrices = df::borrow(&ch.id, keys::settlement_prices());
    if (!prices.enabled) return (false, 0, 0);
    (true, *prices.base_price.borrow(), *prices.collateral_price.borrow())
}

public(package) fun borrow_mut_settlement_prices<T>(
    ch: &mut ClearingHouse<T>,
): &mut SettlementPrices {
    df::borrow_mut(&mut ch.id, keys::settlement_prices())
}

public(package) fun closed_market_adl_prices<T>(ch: &ClearingHouse<T>): (u256, u256) {
    assert_market_is_closed(ch);
    let prices = ch.settlement_prices();
    assert!(
        prices.base_price.is_some() && prices.collateral_price.is_some(),
        ESettlementPricesNotSet,
    );
    (*prices.base_price.borrow(), *prices.collateral_price.borrow())
}

public fun book_price<T>(clearing_house: &ClearingHouse<T>): Option<u256> {
    let book_price = clearing_house.orderbook().book_price();
    if (book_price.is_none()) return option::none();
    option::some(ifixed::from_balance(book_price.destroy_some(), 1_000_000_000))
}

public fun best_price<T>(
    clearing_house: &ClearingHouse<T>,
    side: bool
): Option<u256> {
    let best_price = clearing_house.orderbook().best_price(side);
    if (best_price.is_none()) return option::none();
    option::some(ifixed::from_balance(best_price.destroy_some(), 1_000_000_000))
}

public fun best_price_u64<T>(
    clearing_house: &ClearingHouse<T>,
    side: bool
): Option<u64> {
    clearing_house.orderbook().best_price(side)
}

public fun mark_price<T>(
    clearing_house: &ClearingHouse<T>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
): u256 {
    let (market_params, market_state) = clearing_house.market_objects();
    let (index_price, index_twap_price) =
        market_params.base_oracle_price_and_twap_price(base_oracle, clock);
    market_params.assert_index_twap_divergence_within_limit(index_price, index_twap_price);
    let now = clock.timestamp_ms();
    let book_price = clearing_house.orderbook().book_price_or_index(index_price);
    market_state.calculate_mark_price(market_params, index_twap_price, book_price, now)
}

public fun create_client_order_id(client_order_id: u64): Option<u64> {
    option::some(client_order_id)
}

public fun market_vault<T>(ch: &ClearingHouse<T>): &Vault<T> {
    df::borrow(&ch.id, keys::market_vault())
}

public(package) fun borrow_mut_market_vault<T>(ch: &mut ClearingHouse<T>): &mut Vault<T> {
    df::borrow_mut(&mut ch.id, keys::market_vault())
}

public fun collateral_and_insurance_fund_balances<T>(ch: &ClearingHouse<T>): (u64, u64) {
    let vault = ch.market_vault();
    (vault.collateral_balance.value(), vault.insurance_fund_balance.value())
}

public fun orderbook<T>(ch: &ClearingHouse<T>): &Orderbook {
    &ch.orderbook
}

public(package) fun borrow_mut_orderbook<T>(ch: &mut ClearingHouse<T>): &mut Orderbook {
    &mut ch.orderbook
}

public fun position<T>(
    ch: &ClearingHouse<T>,
    account_id: u64
): &Position {
    df::borrow(&ch.id, keys::position(account_id))
}

public fun exists_position<T>(
    ch: &ClearingHouse<T>,
    account_id: u64
): bool {
    df::exists(&ch.id, keys::position(account_id))
}

public(package) fun borrow_mut_position<T>(
    ch: &mut ClearingHouse<T>,
    account_id: u64,
): &mut Position {
    df::borrow_mut(&mut ch.id, keys::position(account_id))
}

fun borrow_mut_position_from_id(
    ch_id: &mut UID,
    account_id: u64
): &mut Position {
    df::borrow_mut(ch_id, keys::position(account_id))
}

public(package) fun settle_position_funding_and_emit(
    position: &mut Position,
    collateral_price: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
    ch_id: &ID,
    account_id: u64,
) {
    let (settled, collateral_change_usd, collateral_after) = position.settle_position_funding(
        collateral_price,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
    );
    if (settled) {
        events::emit_settled_funding(
            *ch_id,
            account_id,
            collateral_change_usd,
            collateral_after,
            mkt_funding_rate_long,
            mkt_funding_rate_short,
        )
    }
}

fun add_position<T>(
    ch: &mut ClearingHouse<T>,
    account_id: u64,
    position: Position
) {
    assert!(!df::exists(&ch.id, keys::position(account_id)), EPositionAlreadyExists);
    df::add(&mut ch.id, keys::position(account_id), position)
}

public fun collateral_to_deallocate_for_margin_ratio<T>(
    clearing_house: &ClearingHouse<T>,
    account_id: u64,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    margin_ratio: Option<u256>,
): u64 {
    let market_params = clearing_house.market_params();
    let market_state = clearing_house.market_state();
    let scaling_factor = market_params.scaling_factor();
    let market_imr = market_params.margin_ratio_initial();
    let collateral_haircut = market_params.collateral_haircut();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let collateral_price = market_params.collateral_oracle_price(collateral_oracle, clock);
    let (index_price, index_twap_price) =
        market_params.base_oracle_price_and_twap_price(base_oracle, clock);
    market_params.assert_index_twap_divergence_within_limit(index_price, index_twap_price);
    let mark_price = market_state.calculate_mark_price(
        market_params,
        index_twap_price,
        clearing_house.orderbook().book_price_or_index(index_price),
        clock.timestamp_ms(),
    );
    let position = clearing_house.position(account_id);
    let target_margin_ratio = margin_ratio.destroy_or!(position.initial_margin_ratio());
    assert!(
        ifixed::greater_than_eq(target_margin_ratio, market_imr),
        EDeallocateTargetMrTooLow,
    );
    let free_collateral = position.compute_free_collateral_with_fundings(
        collateral_price,
        mark_price,
        target_margin_ratio,
        funding_rate_long,
        funding_rate_short,
        collateral_haircut,
    );
    ifixed::to_balance(free_collateral, scaling_factor)
}

public fun account_id<T>(
    session: &SessionHotPotato<T>,
): u64 {
    session.account_id
}

public fun clearing_house<T>(
    session: &SessionHotPotato<T>,
): &ClearingHouse<T> {
    &session.clearing_house
}

public fun no_domain_executor(ctx: &TxContext): Executor {
    Executor { sender: ctx.sender(), domain: option::none() }
}

public fun domain_executor(uid: &UID, ctx: &TxContext): Executor {
    Executor { sender: ctx.sender(), domain: option::some(uid.to_address()) }
}

public fun executor_sender(executor: &Executor): address {
    executor.sender
}

public fun executor_domain(executor: &Executor): Option<address> {
    executor.domain
}

public fun mark_price_in_session<T>(
    session: &SessionHotPotato<T>,
): u256 {
    session.mark_price
}

public fun summary<T>(
    session: &SessionHotPotato<T>,
): &SessionSummary {
    &session.session_summary
}

public fun tick_rounded_liquidation_mark_price<T>(
    hot_potato: &SessionHotPotato<T>,
): u64 {
    let tick_size = hot_potato.clearing_house.market_params.tick_size();
    let liquidation_price = ifixed::div(
        hot_potato.session_summary.quote_liquidated,
        hot_potato.session_summary.base_liquidated,
    );
    ifixed::to_balance(liquidation_price, 1_000_000_000) / tick_size * tick_size
}

fun session_has_activity(
    session_summary: &SessionSummary,
    maker_events: &vector<FilledMakerOrder>,
    liqee_account_id: &Option<u64>,
): bool {
    liqee_account_id.is_some()
        || session_summary.posted_orders != 0
        || !maker_events.is_empty()
}

public fun filled_base_and_quote(
    session_summary: &SessionSummary,
    side: bool
): (u256, u256) {
    if (side) (session_summary.base_filled_ask, session_summary.quote_filled_ask)
    else (session_summary.base_filled_bid, session_summary.quote_filled_bid)
}

public fun base_filled_bid(
    session_summary: &SessionSummary,
): u256 {
    session_summary.base_filled_bid
}

public fun base_filled_ask(
    session_summary: &SessionSummary,
): u256 {
    session_summary.base_filled_ask
}

public fun posted_orders(
    session_summary: &SessionSummary,
): u64 {
    session_summary.posted_orders
}

public fun execution_price(
    session_summary: &SessionSummary,
    side: bool
): u256 {
    if (side && session_summary.base_filled_ask != 0) {
        ifixed::div(session_summary.quote_filled_ask, session_summary.base_filled_ask)
    } else if (!side && session_summary.base_filled_bid != 0) {
        ifixed::div(session_summary.quote_filled_bid, session_summary.base_filled_bid)
    } else {
        0
    }
}

public fun posted_base_by_side(
    session_summary: &SessionSummary,
): (u256, u256) {
    (session_summary.base_posted_ask, session_summary.base_posted_bid)
}

public fun liquidation_base_quote_and_side(
    session_summary: &SessionSummary,
): (u256, u256, bool) {
    (
        session_summary.base_liquidated,
        session_summary.quote_liquidated,
        session_summary.is_liqee_long,
    )
}

public fun liquidated_size(
    session_summary: &SessionSummary,
): u64 {
    ifixed::to_balance(session_summary.base_liquidated, 1_000_000_000)
}

public fun liquidation_mark_price(
    session_summary: &SessionSummary,
): u256 {
    ifixed::div(session_summary.quote_liquidated, session_summary.base_liquidated)
}

public fun liquidation_mark_price_b9(
    session_summary: &SessionSummary,
): u64 {
    ifixed::to_balance(
        ifixed::div(session_summary.quote_liquidated, session_summary.base_liquidated),
        1_000_000_000,
    )
}

public fun liquidation_bad_debt(
    session_summary: &SessionSummary,
): u256 {
    session_summary.bad_debt
}

fun create_session_summary(): SessionSummary {
    SessionSummary {
        base_filled_ask: 0,
        base_filled_bid: 0,
        quote_filled_ask: 0,
        quote_filled_bid: 0,
        base_posted_ask: 0,
        base_posted_bid: 0,
        posted_orders: 0,
        base_liquidated: 0,
        quote_liquidated: 0,
        is_liqee_long: true,
        bad_debt: 0,
    }
}

public fun create_orderbook<VendorKey, ADMIN_OR_ASSISTANT>(
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    branch_min: u64,
    branches_merge_max: u64,
    branch_max: u64,
    leaf_min: u64,
    leaves_merge_max: u64,
    leaf_max: u64,
    ctx: &mut TxContext,
): Orderbook {
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    orderbook::create_orderbook(
        branch_min,
        branches_merge_max,
        branch_max,
        leaf_min,
        leaves_merge_max,
        leaf_max,
        ctx,
    )
}

/// Creates a market from `params`, built with `market::new_creation_params` and its setters.
public fun create_clearing_house<T, VendorKey, ADMIN_OR_ASSISTANT>(
    orderbook: Orderbook,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &mut Registry,
    coin_metadata: &CoinMetadata<T>,
    clock: &Clock,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_source_id: u16,
    collateral_source_id: u16,
    params: &MarketCreationParams,
    ctx: &mut TxContext,
): ClearingHouse<T> {
    create_clearing_house_(
        orderbook,
        cap,
        registry,
        clock,
        base_oracle,
        collateral_oracle,
        base_source_id,
        collateral_source_id,
        (coin_metadata.get_decimals() as u64),
        params,
        ctx,
    )
}

public fun create_clearing_house_with_currency<T, VendorKey, ADMIN_OR_ASSISTANT>(
    orderbook: Orderbook,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &mut Registry,
    currency: &Currency<T>,
    clock: &Clock,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_source_id: u16,
    collateral_source_id: u16,
    params: &MarketCreationParams,
    ctx: &mut TxContext,
): ClearingHouse<T> {
    create_clearing_house_(
        orderbook,
        cap,
        registry,
        clock,
        base_oracle,
        collateral_oracle,
        base_source_id,
        collateral_source_id,
        (currency.decimals() as u64),
        params,
        ctx,
    )
}

public fun share<T>(ch: ClearingHouse<T>) {
    transfer::share_object(ch)
}

public fun admin_pause_market<T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<PACKAGE, PAUSE_GUARDIAN>,
    registry: &Registry,
    pause_mode: u8,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    assert_market_is_not_closed(clearing_house);
    assert_valid_pause_mode(pause_mode);
    clearing_house.paused = pause_mode
}

public fun admin_resume_market<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    assert_market_is_not_closed(clearing_house);
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    clearing_house.paused = 0
}

entry fun upgrade_version<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    registry: &Registry,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    assert!(clearing_house.version < 1, EInvalidVersionUpgradeValue);
    events::emit_upgraded_version(clearing_house.id.to_inner(), 1);
    clearing_house.version = 1
}

public fun unfreeze_clearing_house<T>(
    clearing_house: &mut ClearingHouse<T>,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
) {
    assert!(is_frozen(clearing_house), ENotFrozen);
    let resume_version: u64 = df::remove(&mut clearing_house.id, keys::frozen_version());
    assert!(resume_version <= 1, EInvalidResumeVersion);
    clearing_house.version = resume_version;
    events::emit_unfroze(clearing_house.id.to_inner(), resume_version)
}

public fun freeze_clearing_house<T>(
    clearing_house: &mut ClearingHouse<T>,
    registry: &Registry,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    assert_package_version(clearing_house);
    registry.assert_authority_cap_is_authorized(cap);
    let resume_version = clearing_house.version;
    df::add(&mut clearing_house.id, keys::frozen_version(), resume_version);
    // No package version accepts u64::MAX, so every versioned entry point fails until unfrozen.
    clearing_house.version = u64::max_value!();
    events::emit_froze(clearing_house.id.to_inner(), resume_version, object::id(cap))
}

public fun pause_market<T, VendorKey, ADMIN_OR_ASSISTANT_OR_PAUSE_GUARDIAN>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT_OR_PAUSE_GUARDIAN>,
    registry: &Registry,
    pause_mode: u8,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    assert_market_is_not_closed(clearing_house);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    // Only the vendor admin, its assistants and pause guardians may pause a market.
    let cap_role = type_name::with_defining_ids<ADMIN_OR_ASSISTANT_OR_PAUSE_GUARDIAN>();
    let can_pause = cap_role == type_name::with_defining_ids<ADMIN>()
        || cap_role == type_name::with_defining_ids<ASSISTANT>()
        || cap_role == type_name::with_defining_ids<PAUSE_GUARDIAN>();
    assert!(can_pause, EInvalidAuthorityCap);
    registry.assert_authority_cap_is_authorized(cap);
    assert_valid_pause_mode(pause_mode);
    clearing_house.paused = pause_mode
}

public fun resume_market<T, VendorKey, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    assert_market_is_not_closed(clearing_house);
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    clearing_house.paused = 0
}

public fun register_market<VendorKey, ADMIN_OR_ASSISTANT, T>(
    registry: &mut Registry,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    clearing_house: &ClearingHouse<T>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let market_params = clearing_house.market_params();
    registry.register_market<T>(
        market_params.base_storage_id(),
        market_params.base_source_id(),
        market_params.collateral_storage_id(),
        market_params.collateral_source_id(),
        market_params.scaling_factor(),
        clearing_house.id.to_inner(),
    )
}

public fun remove_registered_market<VendorKey, ADMIN_OR_ASSISTANT, T>(
    registry: &mut Registry,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    clearing_house: &ClearingHouse<T>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    registry.remove_registered_market<T>(clearing_house.id.to_inner())
}

public fun close_market<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    assert_market_is_not_closed(clearing_house);
    clearing_house.paused = 1;
    let ch_id = clearing_house.id.to_inner();
    market::try_update_fundings(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        clock.timestamp_ms(),
        &ch_id,
    );
    // Settlement prices are set (and later enabled) by the vendor once the market is closed.
    df::add(
        &mut clearing_house.id,
        keys::settlement_prices(),
        SettlementPrices {
            base_price: option::none(),
            collateral_price: option::none(),
            enabled: false,
        },
    );
    events::emit_closed_market(clearing_house.id.to_inner())
}

public fun set_settlement_prices<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    base_settlement_price: u256,
    collateral_settlement_price: u256,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    assert_market_is_closed(clearing_house);
    assert_settlement_prices(base_settlement_price, collateral_settlement_price);
    assert!(!clearing_house.settlement_prices().enabled, ESettlementAlreadyEnabled);
    let ch_id = clearing_house.id.to_inner();
    let prices = clearing_house.borrow_mut_settlement_prices();
    prices.base_price = option::some(base_settlement_price);
    prices.collateral_price = option::some(collateral_settlement_price);
    events::emit_updated_settlement_prices(ch_id, base_settlement_price, collateral_settlement_price, false)
}

public fun enable_settlement<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    assert_market_is_closed(clearing_house);
    let ch_id = clearing_house.id.to_inner();
    let prices = clearing_house.borrow_mut_settlement_prices();
    assert!(
        prices.base_price.is_some() && prices.collateral_price.is_some(),
        ESettlementPricesNotSet,
    );
    prices.enabled = true;
    events::emit_updated_settlement_prices(ch_id, *prices.base_price.borrow(), *prices.collateral_price.borrow(), true)
}

public fun set_fee_params<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    maker_fee: Option<u256>,
    taker_fee: Option<u256>,
    liquidation_fee: Option<u256>,
    insurance_fund_fee: Option<u256>,
    priority_taker_fee: Option<Option<u256>>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_market_params()
        .set_fee_params(
            registry.config(),
            &ch_id,
            maker_fee,
            taker_fee,
            liquidation_fee,
            insurance_fund_fee,
            priority_taker_fee,
        )
}

public fun set_twap_params<VendorKey, ADMIN_OR_ASSISTANT_OR_MAINTENANCE, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT_OR_MAINTENANCE>,
    registry: &Registry,
    funding_frequency_ms: Option<u64>,
    funding_period_ms: Option<u64>,
    premium_twap_frequency_ms: Option<u64>,
    premium_twap_period_ms: Option<u64>,
    spread_twap_frequency_ms: Option<u64>,
    spread_twap_period_ms: Option<u64>,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_or_maintenance_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let ch_id = clearing_house.id.to_inner();
    // Settle fundings under the current parameters before they change.
    market::try_update_fundings(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        clock.timestamp_ms(),
        &ch_id,
    );
    clearing_house
        .borrow_mut_market_params()
        .set_twap_params(
            registry.config(),
            &ch_id,
            funding_frequency_ms,
            funding_period_ms,
            premium_twap_frequency_ms,
            premium_twap_period_ms,
            spread_twap_frequency_ms,
            spread_twap_period_ms,
        )
}

public fun set_core_params<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    lot_size: Option<u64>,
    tick_size: Option<u64>,
    collateral_haircut: Option<u256>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_market_params()
        .set_core_params(&ch_id, lot_size, tick_size, collateral_haircut)
}

public fun set_risk_limit_params<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    min_order_usd_value: Option<u256>,
    max_pending_orders: Option<u64>,
    max_open_interest: Option<u256>,
    max_open_interest_threshold: Option<u256>,
    max_open_interest_position_percent: Option<u256>,
    max_book_index_spread: Option<u256>,
    max_index_twap_divergence: Option<u256>,
    max_bad_debt: Option<u256>,
    max_socialize_losses_mr_decrease: Option<u256>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_market_params()
        .set_risk_limit_params(
            registry.config(),
            &ch_id,
            min_order_usd_value,
            max_pending_orders,
            max_open_interest,
            max_open_interest_threshold,
            max_open_interest_position_percent,
            max_book_index_spread,
            max_index_twap_divergence,
            max_bad_debt,
            max_socialize_losses_mr_decrease,
        )
}

public fun set_base_oracle_params<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &mut Registry,
    price_feed_storage: &PriceFeedStorage,
    source_id: Option<u16>,
    oracle_tolerance: Option<u64>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let storage_id = price_feed_storage.storage_id();
    let new_source_id = if (source_id.is_some()) {
        *source_id.borrow()
    } else {
        clearing_house.market_params().base_source_id()
    };
    assert!(price_feed_storage.contains(new_source_id), EPriceFeedSourceDoesNotExist);
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_market_params()
        .set_base_oracle_params(
            registry.config(),
            &ch_id,
            storage_id,
            option::some(new_source_id),
            oracle_tolerance,
        );
    registry.set_base_oracle_params_<T>(ch_id, storage_id, new_source_id)
}

public fun set_collateral_oracle_params<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    registry: &mut Registry,
    price_feed_storage: &PriceFeedStorage,
    source_id: Option<u16>,
    oracle_tolerance: Option<u64>,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    let storage_id = price_feed_storage.storage_id();
    let new_source_id = if (source_id.is_some()) {
        *source_id.borrow()
    } else {
        clearing_house.market_params().collateral_source_id()
    };
    assert!(price_feed_storage.contains(new_source_id), EPriceFeedSourceDoesNotExist);
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_market_params()
        .set_collateral_oracle_params(
            registry.config(),
            &ch_id,
            storage_id,
            option::some(new_source_id),
            oracle_tolerance,
        );
    registry.set_collateral_oracle_params_<T>(ch_id, storage_id, new_source_id)
}

public fun create_margin_ratios_proposal<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
    delay_ms: u64,
    margin_ratio_initial: u256,
    margin_ratio_maintenance: u256,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    assert!(
        !df::exists(&clearing_house.id, keys::margin_ratio_proposal()),
        EProposalAlreadyExists,
    );
    let config = registry.config();
    assert!(
        config.min_proposal_delay_ms() <= delay_ms && delay_ms <= config.max_proposal_delay_ms(),
        EInvalidProposalDelay,
    );
    market::assert_margin_ratios(margin_ratio_initial, margin_ratio_maintenance);
    let (liquidation_fee, insurance_fund_fee) =
        clearing_house.market_params.liquidation_fee_rates();
    market::assert_liquidation_fees_against_mmr(
        margin_ratio_maintenance,
        liquidation_fee,
        insurance_fund_fee,
    );
    let proposal = MarginRatioProposal {
        maturity: clock.timestamp_ms() + delay_ms,
        margin_ratio_initial,
        margin_ratio_maintenance,
    };
    df::add(&mut clearing_house.id, keys::margin_ratio_proposal(), proposal)
}

public fun delete_margin_ratios_proposal<VendorKey, ADMIN_OR_ASSISTANT, T>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &Registry,
) {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let key = keys::margin_ratio_proposal();
    assert!(df::exists(&clearing_house.id, key), EProposalDoesNotExist);
    let MarginRatioProposal { .. } = df::remove(&mut clearing_house.id, key);
}

public fun commit_margin_ratios_proposal<T>(
    clearing_house: &mut ClearingHouse<T>,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let key = keys::margin_ratio_proposal();
    assert!(df::exists(&clearing_house.id, key), EProposalDoesNotExist);
    let MarginRatioProposal { maturity, margin_ratio_initial, margin_ratio_maintenance } =
        df::remove(&mut clearing_house.id, key);
    assert!(maturity <= clock.timestamp_ms(), EPrematureProposal);
    clearing_house
        .market_params
        .update_margin_ratios(margin_ratio_initial, margin_ratio_maintenance);
    events::emit_updated_margin_ratios(clearing_house.id.to_inner(), margin_ratio_initial, margin_ratio_maintenance)
}

public fun donate_to_insurance_fund<T>(
    clearing_house: &mut ClearingHouse<T>,
    coin: Coin<T>,
    ctx: &mut TxContext
) {
    assert_package_version(clearing_house);
    let amount = coin.value();
    assert!(amount != 0, EDepositOrWithdrawAmountZero);
    let new_balance = clearing_house
        .borrow_mut_market_vault()
        .insurance_fund_balance
        .join(coin.into_balance());
    events::emit_donated_to_insurance_fund(ctx.sender(), clearing_house.id.to_inner(), amount, new_balance)
}

public fun update_funding<T>(
    clearing_house: &mut ClearingHouse<T>,
    oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let ch_id = clearing_house.id.to_inner();
    let book_price = clearing_house.book_price();
    market::try_update_funding(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        oracle,
        clock,
        &ch_id,
        book_price,
    )
}

public fun update_twaps<T>(
    clearing_house: &mut ClearingHouse<T>,
    oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let ch_id = clearing_house.id.to_inner();
    let book_price = clearing_house.book_price();
    market::try_update_twaps(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        oracle,
        clock,
        &ch_id,
        book_price,
    )
}

public fun settle_position_funding<T>(
    clearing_house: &mut ClearingHouse<T>,
    oracle: &PriceFeedStorage,
    account_id: u64,
    clock: &Clock,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let collateral_price = clearing_house.market_params.collateral_oracle_price(oracle, clock);
    let (funding_rate_long, funding_rate_short) = clearing_house.market_state.cum_funding_rates();
    let ch_id = clearing_house.id.to_inner();
    settle_position_funding_and_emit(
        clearing_house.borrow_mut_position(account_id),
        collateral_price,
        funding_rate_long,
        funding_rate_short,
        &ch_id,
        account_id,
    )
}

public fun withdraw_fees<T, VendorKey>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, TREASURY>,
    registry: &Registry,
    ctx: &mut TxContext,
): Coin<T> {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let scaling_factor = clearing_house.market_params.scaling_factor();
    let fees = ifixed::to_balance(clearing_house.market_state.fees_accrued(), scaling_factor);
    if (fees == 0) return coin::zero(ctx);
    // Only the whole collateral units are withdrawn; the sub-unit dust stays accrued.
    clearing_house.market_state.sub_fees_accrued(ifixed::from_balance(fees, scaling_factor));
    let ch_id = clearing_house.id.to_inner();
    let vault = clearing_house.borrow_mut_market_vault();
    let fees_coin = coin::take(&mut vault.collateral_balance, fees, ctx);
    events::emit_withdrew_fees(ctx.sender(), ch_id, fees, vault.collateral_balance.value());
    fees_coin
}

public fun withdraw_insurance_fund<T, VendorKey>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, TREASURY>,
    registry: &Registry,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    if (amount == 0) return coin::zero(ctx);
    let market_params = &clearing_house.market_params;
    let scaling_factor = market_params.scaling_factor();
    // A closed market values open interest and the fund at its settlement prices.
    let market_is_closed = df::exists(&clearing_house.id, keys::settlement_prices());
    let (base_price, collateral_price) = if (market_is_closed) {
        let settlement = clearing_house.settlement_prices();
        assert!(
            settlement.base_price.is_some() && settlement.collateral_price.is_some(),
            ESettlementPricesNotSet,
        );
        (*settlement.base_price.borrow(), *settlement.collateral_price.borrow())
    } else {
        let collateral_price = market_params.collateral_oracle_price(collateral_oracle, clock);
        let (index_price, index_twap_price) =
            market_params.base_oracle_price_and_twap_price(base_oracle, clock);
        market_params.assert_index_twap_divergence_within_limit(index_price, index_twap_price);
        (index_price, collateral_price)
    };
    let open_interest_usd = ifixed::mul(
        ifixed::abs(clearing_house.market_state.open_interest()),
        base_price,
    );
    let vault = clearing_house.borrow_mut_market_vault();
    let insurance_fund_usd = ifixed::mul(
        ifixed::from_balance(vault.insurance_fund_balance.value(), scaling_factor),
        collateral_price,
    );
    // The fund must keep a configured fraction of the open interest notional as reserve.
    let reserve_usd = ifixed::mul(
        registry.config().insurance_open_interest_fraction(),
        open_interest_usd,
    );
    let surplus_usd = ifixed::sub(insurance_fund_usd, reserve_usd);
    assert!(!ifixed::is_neg(surplus_usd), EInsufficientInsuranceSurplus);
    let surplus = ifixed::to_balance(ifixed::div(surplus_usd, collateral_price), scaling_factor);
    assert!(amount <= surplus, EInsufficientInsuranceSurplus);
    let withdrawn = coin::take(&mut vault.insurance_fund_balance, amount, ctx);
    let insurance_fund_balance_after = vault.insurance_fund_balance.value();
    events::emit_withdrew_insurance_fund(ctx.sender(), clearing_house.id.to_inner(), amount, insurance_fund_balance_after);
    withdrawn
}

public fun try_cancel_stale_orders<T, VendorKey>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<VENDOR<VendorKey>, MAINTENANCE>,
    registry: &Registry,
    account_id: u64,
    order_ids: &vector<u128>,
    clock: &Clock,
): vector<bool> {
    assert_package_version(clearing_house);
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    registry.assert_vendor_has_ownership_over_clearing_house(cap, clearing_house.id.as_inner());
    let (account_base, _) = clearing_house.position(account_id).base_and_quote_amounts();
    try_cancel_orders_(
        clearing_house,
        account_id,
        order_ids,
        option::some(clock.timestamp_ms()),
        account_base,
    )
}

public fun allocate_collateral<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    amount: u64,
) {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    account.assert_authority_cap_is_valid(cap);
    assert!(amount != 0, EDepositOrWithdrawAmountZero);
    let collateral = account.borrow_mut_collateral().split(amount);
    clearing_house.borrow_mut_market_vault().collateral_balance.join(collateral);
    let scaling_factor = clearing_house.market_params.scaling_factor();
    clearing_house
        .borrow_mut_position(account.account_id())
        .add_to_collateral(ifixed::from_balance(amount, scaling_factor));
    events::emit_allocated_collateral(clearing_house.id.to_inner(), account.account_id(), amount)
}

public fun deallocate_collateral<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount: u64,
    clock: &Clock,
): u64 {
    deallocate_collateral_(
        clearing_house,
        cap,
        account,
        base_oracle,
        collateral_oracle,
        option::some(amount),
        clock,
    )
}

public fun deallocate_free_collateral<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): u64 {
    deallocate_collateral_(
        clearing_house,
        cap,
        account,
        base_oracle,
        collateral_oracle,
        option::none(),
        clock,
    )
}

public fun create_market_position<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &Account<T>,
) {
    account.assert_authority_cap_is_valid(cap);
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let (funding_rate_long, funding_rate_short) = clearing_house.market_state.cum_funding_rates();
    let account_id = account.account_id();
    add_position(
        clearing_house,
        account_id,
        position::create_position(funding_rate_long, funding_rate_short),
    );
    events::emit_created_position(clearing_house.id.to_inner(), account_id, funding_rate_long, funding_rate_short)
}

public fun set_position_initial_margin_ratio<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &Account<T>,
    initial_margin_ratio: u256
) {
    account.assert_authority_cap_is_valid(cap);
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    let (market_params, _) = clearing_house.market_objects();
    let market_imr = market_params.margin_ratio_initial();
    let account_id = account.account_id();
    let ch_id = clearing_house.id.to_inner();
    clearing_house
        .borrow_mut_position(account_id)
        .set_initial_margin_ratio(initial_margin_ratio, market_imr);
    events::emit_set_position_initial_margin_ratio(ch_id, account_id, initial_margin_ratio)
}

public fun cancel_orders<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &Account<T>,
    order_ids: vector<u128>,
) {
    account.assert_authority_cap_is_valid(cap);
    assert_package_version(clearing_house);
    assert_market_allows_order_cancellation(clearing_house);
    // Cancelation reason 0: canceled by the user.
    cancel_orders_(clearing_house, account.account_id(), &order_ids, 0)
}

public fun try_cancel_orders<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &Account<T>,
    order_ids: &vector<u128>,
): vector<bool> {
    account.assert_authority_cap_is_valid(cap);
    assert_package_version(clearing_house);
    assert_market_allows_order_cancellation(clearing_house);
    try_cancel_orders_(clearing_house, account.account_id(), order_ids, option::none(), 0)
}

public fun close_position_at_settlement_prices<T>(
    clearing_house: &mut ClearingHouse<T>,
    account: &mut Account<T>,
    order_ids: &vector<u128>,
) {
    assert_package_version(clearing_house);
    assert_market_is_paused(clearing_house);
    assert_market_is_closed(clearing_house);
    let account_id = account.account_id();
    let ch_id = clearing_house.id.to_inner();
    let settlement_prices = clearing_house.settlement_prices();
    assert!(settlement_prices.enabled, ESettlementPricesDisabled);
    let base_price = *settlement_prices.base_price.borrow();
    let collateral_price = *settlement_prices.collateral_price.borrow();
    if (!order_ids.is_empty()) {
        // Cancelation reason 3: market closed.
        cancel_orders_(clearing_house, account_id, order_ids, 3)
    };
    let (funding_rate_long, funding_rate_short) = clearing_house.market_state.cum_funding_rates();
    let scaling_factor = clearing_house.market_params.scaling_factor();
    let position = clearing_house.borrow_mut_position(account_id);
    let (pending_asks, pending_bids) = position.pending_base_amounts_by_side();
    let pending_orders = position.pending_order_count();
    assert!(
        pending_asks == 0 && pending_bids == 0 && pending_orders == 0,
        EPendingOrdersNotCanceled,
    );
    settle_position_funding_and_emit(
        position,
        collateral_price,
        funding_rate_long,
        funding_rate_short,
        &ch_id,
        account_id,
    );
    let (base, quote) = position.base_and_quote_amounts();
    let is_short = ifixed::is_neg(base);
    let mut bad_debt = 0;
    let mut pnl = 0;
    if (base != 0) {
        // Close the whole position at the base settlement price.
        let size = ifixed::abs(base);
        (pnl, _) = position.add_base_to_position(!is_short, size, ifixed::mul(size, base_price));
        position.add_to_collateral_usd(pnl, collateral_price);
    };
    if (ifixed::is_neg(position.collateral())) {
        bad_debt = position.reset_collateral();
    };
    let collateral = position.collateral();
    let collateral_amount = ifixed::to_balance(collateral, scaling_factor);
    position.sub_from_collateral(collateral);
    // Negative collateral left after closing is covered by the insurance fund.
    if (bad_debt != 0) {
        let vault = clearing_house.borrow_mut_market_vault();
        assert!(
            ifixed::greater_than_eq(
                ifixed::from_balance(vault.insurance_fund_balance.value(), scaling_factor),
                bad_debt,
            ),
            EInsufficientSettlementInsurance,
        );
        transfer_from_insurance_fund_to_vault(vault, bad_debt, scaling_factor)
    };
    let vault = clearing_house.borrow_mut_market_vault();
    assert!(
        vault.collateral_balance.value() >= collateral_amount,
        EInsufficientVaultCollateral,
    );
    let collateral_out = vault.collateral_balance.split(collateral_amount);
    account.borrow_mut_collateral().join(collateral_out);
    // Only long positions count towards open interest.
    clearing_house.market_state.add_to_open_interest(ifixed::neg(ifixed::max(base, 0)));
    events::emit_closed_position_at_settlement_prices(ch_id, account_id, pnl, base, quote, collateral_amount, bad_debt)
}

public fun start_session<T, ADMIN_OR_ASSISTANT>(
    clearing_house: ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
    ctx: &TxContext
): SessionHotPotato<T> {
    account.assert_authority_cap_is_valid(cap);
    assert_package_version(&clearing_house);
    assert_market_is_not_paused(&clearing_house);
    start_session_(
        clearing_house,
        account.account_id(),
        base_oracle,
        collateral_oracle,
        ctx.gas_price() > ctx.reference_gas_price(),
        integrator_info,
        clock,
    )
}

public fun place_limit_order<T>(
    hot_potato: &mut SessionHotPotato<T>,
    side: bool,
    size: u64,
    price: u64,
    order_type: u64,
    client_order_id: Option<u64>,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>
): Option<u128> {
    assert_package_version(&hot_potato.clearing_house);
    // The price lives in the upper bits of an order id, below the top (side) bit.
    assert!(price != 0 && price < 1 << 63, EInvalidOrderPrice);
    let tick_size = hot_potato.clearing_house.market_params.tick_size();
    assert!(price % tick_size == 0, EPriceNotMultipleOfTickSize);
    let order_size = assert_reduce_only(hot_potato, side, size, reduce_only);
    let lot_size = hot_potato.clearing_house.market_params.lot_size();
    assert!(order_size % lot_size == 0, ESizeNotMultipleOfLotSize);
    assert!(order_size != 0, ESizeOrPositionZero);
    let (posted_size, order_id) = execute_limit_order(
        hot_potato,
        side,
        order_size,
        price,
        order_type,
        client_order_id,
        reduce_only,
        expiration_timestamp_ms,
    );
    // An order that did not match at all must meet the minimum order value.
    if (posted_size == order_size) {
        let min_order_usd_value = hot_potato.clearing_house.market_params.min_order_usd_value();
        assert_order_value(posted_size, hot_potato.mark_price, min_order_usd_value)
    };
    order_id
}

public fun place_market_order<T>(
    hot_potato: &mut SessionHotPotato<T>,
    side: bool,
    size: u64,
    reduce_only: bool,
) {
    assert_package_version(&hot_potato.clearing_house);
    let order_size = assert_reduce_only(hot_potato, side, size, reduce_only);
    let lot_size = hot_potato.clearing_house.market_params.lot_size();
    assert!(order_size % lot_size == 0, ESizeNotMultipleOfLotSize);
    assert!(order_size != 0, ESizeOrPositionZero);
    execute_market_order(hot_potato, side, order_size)
}

public fun liquidate<T>(
    hot_potato: &mut SessionHotPotato<T>,
    liqee_account_id: u64,
    cancel_order_ids: &vector<u128>
) {
    assert_package_version(&hot_potato.clearing_house);
    assert!(hot_potato.account_id != liqee_account_id, ESelfLiquidation);
    let ch_id = hot_potato.clearing_house.id.to_inner();
    let (orderbook, maker_events, session_summary) = (
        &mut hot_potato.clearing_house.orderbook,
        &hot_potato.maker_events,
        &hot_potato.session_summary,
    );
    // A liquidation must be the first action of its session.
    assert!(
        maker_events.length() == 0
            && session_summary.posted_orders == 0
            && hot_potato.liqee_account_id.is_none(),
        ELiquidateNotFirstOperation,
    );
    let has_orders_to_cancel = cancel_order_ids.length() != 0;
    let (liqee_base_ask_cancel, liqee_base_bid_cancel, liqee_pending_orders_cancel) =
        if (has_orders_to_cancel) {
            // Cancelation reason 1: liquidation.
            force_cancel_orders(orderbook, liqee_account_id, cancel_order_ids, ch_id, 1)
        } else {
            (0, 0, 0)
        };
    execute_liquidation(
        hot_potato,
        liqee_account_id,
        liqee_base_ask_cancel,
        liqee_base_bid_cancel,
        liqee_pending_orders_cancel,
    )
}

public fun end_session<T, ADMIN_OR_ASSISTANT>(
    hot_potato: SessionHotPotato<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    allocate_missing_margin: bool,
    deallocate_free_collateral: bool,
): (ClearingHouse<T>, SessionSummary) {
    assert_package_version(&hot_potato.clearing_house);
    account.assert_authority_cap_is_valid(cap);
    end_session_(hot_potato, account, allocate_missing_margin, deallocate_free_collateral, false)
}

public(package) fun end_session_<T>(
    hot_potato: SessionHotPotato<T>,
    account: &mut Account<T>,
    allocate_missing_margin: bool,
    deallocate_free_collateral: bool,
    allow_empty_session: bool,
): (ClearingHouse<T>, SessionSummary) {
    assert!(
        hot_potato.account_id() == account.account_id(),
        EWrongAccountIdForAllocation,
    );
    let SessionHotPotato {
        mut clearing_house,
        account_id,
        timestamp_ms: _,
        collateral_price,
        mark_price,
        uses_priority_gas_price,
        margin_before,
        min_margin_before,
        position_base_before,
        mut total_open_interest,
        mut total_fees,
        taker_pending_cancelled,
        maker_events,
        integrator_info,
        liqee_account_id,
        liquidator_fees,
        session_summary,
    } = hot_potato;
    let ch_id = clearing_house.id.to_inner();
    let has_maker_fills = !maker_events.is_empty();
    let is_liquidation = liqee_account_id.is_some();
    let has_activity = session_has_activity(&session_summary, &maker_events, &liqee_account_id);
    assert!(allow_empty_session || has_activity, EEmptySession);
    let book_price = if (has_maker_fills) {
        clearing_house.orderbook.book_price()
    } else {
        option::none()
    };

    let (market_params, market_state) = clearing_house.market_objects();
    let market_imr = market_params.margin_ratio_initial();
    let market_mmr = market_params.margin_ratio_maintenance();
    let collateral_haircut = market_params.collateral_haircut();
    let taker_fee = market_params.taker_fee();
    let priority_taker_fee = market_params.priority_taker_fee();
    let max_pending_orders = market_params.max_pending_orders();
    let scaling_factor = market_params.scaling_factor();
    let max_open_interest = market_params.max_open_interest();
    let (max_open_interest_threshold, max_open_interest_position_percent) =
        market_params.max_open_interest_position_params();
    let open_interest_before = market_state.open_interest();
    // Socializing the liquidation's bad debt moved the cumulative funding rates, so the
    // liquidator's position has to be settled against the new rates.
    let has_bad_debt = session_summary.bad_debt != 0;
    let (funding_rate_long, funding_rate_short) = if (has_bad_debt) {
        market_state.cum_funding_rates()
    } else {
        (0, 0)
    };

    let position = clearing_house.borrow_mut_position(account_id);
    let mut base_before_trades = position_base_before;
    // The liquidator takes over the liquidated base at the liquidation price.
    if (is_liquidation) {
        let (base_before_liquidation, _) = position.base_and_quote_amounts();
        if (has_bad_debt) {
            settle_position_funding_and_emit(
                position,
                collateral_price,
                funding_rate_long,
                funding_rate_short,
                &ch_id,
                account_id,
            )
        };
        let (liqor_pnl, _) = if (session_summary.base_liquidated != 0) {
            position.add_base_to_position(
                !session_summary.is_liqee_long,
                session_summary.base_liquidated,
                session_summary.quote_liquidated,
            )
        } else {
            (0, 0)
        };
        position.add_to_collateral_usd(ifixed::add(liqor_pnl, liquidator_fees), collateral_price);
        let (base_after_liquidation, _) = position.base_and_quote_amounts();
        base_before_trades = base_after_liquidation;
        total_open_interest = ifixed::add(
            total_open_interest,
            ifixed::sub(
                ifixed::max(base_after_liquidation, 0),
                ifixed::max(base_before_liquidation, 0),
            ),
        );
        events::emit_performed_liquidation(
            ch_id,
            liqee_account_id.destroy_some(),
            account_id,
            session_summary.is_liqee_long,
            session_summary.base_liquidated,
            session_summary.quote_liquidated,
            liqor_pnl,
            liquidator_fees,
            mark_price,
        )
    };
    if (has_maker_fills) {
        events::emit_filled_maker_orders(maker_events, book_price)
    };

    // Taker fills are netted per side over the whole session and settled once.
    let has_taker_fills =
        session_summary.base_filled_ask != 0 || session_summary.base_filled_bid != 0;
    let (taker_fees, integrator_fees, taker_open_interest_delta) = if (has_taker_fills) {
        let mut taker_fee_rate = taker_fee;
        if (uses_priority_gas_price) {
            let priority_fee_rate = market::resolve_priority_taker_fee(priority_taker_fee);
            if (priority_fee_rate != 0) {
                taker_fee_rate = ifixed::add(taker_fee_rate, priority_fee_rate);
            }
        };
        let integrator_fee_rate;
        let integrator_id;
        if (integrator_info.is_some()) {
            let info = integrator_info.borrow();
            integrator_fee_rate = info.integrator_fee();
            integrator_id = option::some(info.integrator_id());
        } else {
            integrator_fee_rate = 0;
            integrator_id = option::none();
        };
        let (taker_pnl, taker_fees, integrator_fees, taker_open_interest_delta) = position
            .apply_taker_fills_and_settle(
                collateral_price,
                session_summary.base_filled_ask,
                session_summary.quote_filled_ask,
                session_summary.base_filled_bid,
                session_summary.quote_filled_bid,
                taker_fee_rate,
                integrator_fee_rate,
            );
        events::emit_filled_taker_order(
            ch_id,
            account_id,
            taker_pnl,
            taker_fees,
            integrator_id,
            integrator_fees,
            session_summary.base_filled_ask,
            session_summary.quote_filled_ask,
            session_summary.base_filled_bid,
            session_summary.quote_filled_bid,
            mark_price,
        );
        (taker_fees, integrator_fees, taker_open_interest_delta)
    } else {
        (0, 0, 0)
    };
    process_post(position, max_pending_orders, &session_summary);

    let effective_imr = position.effective_initial_margin_ratio(market_imr);
    let (base_after, _) = position.base_and_quote_amounts();
    let (margin, min_margin, free_collateral) = if (deallocate_free_collateral) {
        position.compute_margin_and_free_collateral(
            collateral_price,
            mark_price,
            effective_imr,
            collateral_haircut,
        )
    } else {
        let (margin, min_margin) = position.compute_margin_and_requirement(
            collateral_price,
            mark_price,
            effective_imr,
            collateral_haircut,
        );
        (margin, min_margin, 0)
    };
    let (collateral_amount, is_allocation) = if (ifixed::greater_than(min_margin, margin)) {
        if (allocate_missing_margin) {
            let collateral_needed = collateral_for_margin_increase(
                position.collateral(),
                collateral_price,
                collateral_haircut,
                ifixed::sub(min_margin, margin),
            );
            assert!(!ifixed::is_neg(margin_before), EPositionBadDebt);
            // Round up to whole collateral units.
            let amount = (((collateral_needed + scaling_factor - 1) / scaling_factor) as u64);
            let added_collateral = (amount as u256) * scaling_factor;
            position.add_to_collateral(added_collateral);
            (amount, true)
        } else {
            assert!(!is_liquidation, ELiquidationRequiresMissingMarginAllocation);
            assert!(!taker_pending_cancelled, EStalePendingRepostRequiresInitialMargin);
            assert!(
                session_summary.posted_orders == 0
                    || ifixed::greater_than_eq(
                        margin,
                        position.margin_requirement(mark_price, market_mmr),
                    ),
                EBelowMmrCannotRestOrder,
            );
            position::ensure_margin_requirements(
                margin_before,
                min_margin_before,
                margin,
                min_margin,
                position_base_before,
                base_after,
            );
            (0, false)
        }
    } else if (deallocate_free_collateral) {
        let amount = ifixed::to_balance(free_collateral, scaling_factor);
        if (free_collateral != 0) {
            position.sub_from_collateral(free_collateral)
        };
        (amount, false)
    } else {
        (0, false)
    };
    if (collateral_amount != 0) {
        if (is_allocation) {
            let account_collateral = account.borrow_mut_collateral();
            assert!(
                collateral_amount <= account_collateral.value(),
                ENotEnoughCollateralToAllocateForSession,
            );
            clearing_house
                .borrow_mut_market_vault()
                .collateral_balance
                .join(account_collateral.split(collateral_amount));
            events::emit_allocated_collateral(ch_id, account_id, collateral_amount)
        } else {
            withdraw_vault_collateral(
                clearing_house.borrow_mut_market_vault(),
                account.borrow_mut_collateral(),
                collateral_amount,
            );
            events::emit_deallocated_collateral(ch_id, account_id, collateral_amount)
        }
    };
    if (integrator_info.is_some()) {
        let _ = account.validate_session_integrator_info(integrator_info.borrow());
    };

    total_fees = ifixed::add(total_fees, ifixed::add(taker_fees, integrator_fees));
    total_open_interest = ifixed::add(total_open_interest, taker_open_interest_delta);
    assert!(!ifixed::is_neg(total_fees), ENegativeFeesAccrued);
    let open_interest_after = ifixed::add(open_interest_before, total_open_interest);
    if (total_fees != 0 || total_open_interest != 0) {
        let market_state = clearing_house.borrow_mut_market_state();
        market_state.add_fees_accrued_usd(total_fees, collateral_price);
        market_state.add_to_open_interest(total_open_interest);
        // A session may always reduce open interest, even while above the cap.
        assert!(
            ifixed::less_than_eq(open_interest_after, max_open_interest)
                || ifixed::less_than_eq(open_interest_after, open_interest_before),
            EMaxOpenInterestSurpassed,
        );
        let fees_accrued = market_state.fees_accrued();
        events::emit_updated_open_interest_and_fees_accrued(ch_id, open_interest_after, fees_accrued)
    };
    // Past the threshold, a position that grew may not exceed its share of open interest.
    if (
        ifixed::greater_than(open_interest_after, max_open_interest_threshold)
            && ifixed::greater_than(ifixed::abs(base_after), ifixed::abs(base_before_trades))
    ) {
        assert!(
            ifixed::less_than_eq(
                ifixed::div(ifixed::abs(base_after), open_interest_after),
                max_open_interest_position_percent,
            ),
            EMaxOpenInterestPositionPercentSurpassed,
        )
    };
    (clearing_house, session_summary)
}

fun execute_limit_order<T>(
    hot_potato: &mut SessionHotPotato<T>,
    side: bool,
    mut size: u64,
    price: u64,
    order_type: u64,
    client_order_id: Option<u64>,
    reduce_only: bool,
    expiration_timestamp_ms: Option<u64>,
): (u64, Option<u128>) {
    // 0 = good-till-cancel, 1 = fill-or-kill, 2 = post-only, 3 = immediate-or-cancel.
    assert!(order_type < 4, EInvalidOrderType);
    let ch_id = hot_potato.clearing_house.id.to_inner();
    let market_params = &hot_potato.clearing_house.market_params;
    let market_state = &hot_potato.clearing_house.market_state;
    let maker_fee = market_params.maker_fee();
    let (liquidation_fee, _) = market_params.liquidation_fee_rates();
    let collateral_haircut = market_params.collateral_haircut();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let open_interest = market_state.open_interest();
    let (max_open_interest_threshold, max_open_interest_position_percent) =
        market_params.max_open_interest_position_params();
    let is_ask = side;
    // Makers rest on the opposite side of the book (ask = true, bid = false).
    let maker_side = if (is_ask) false else true;
    let (
        clearing_house_id,
        orderbook,
        session_summary,
        taker_pending_cancelled,
        maker_events,
        taker_account_id,
        timestamp_ms,
        collateral_price,
        mark_price,
    ) = (
        &mut hot_potato.clearing_house.id,
        &mut hot_potato.clearing_house.orderbook,
        &mut hot_potato.session_summary,
        &mut hot_potato.taker_pending_cancelled,
        &mut hot_potato.maker_events,
        hot_potato.account_id,
        hot_potato.timestamp_ms,
        hot_potato.collateral_price,
        hot_potato.mark_price,
    );
    assert!(
        expiration_timestamp_ms.get_with_default(u64::max_value!()) > timestamp_ms,
        EInvalidExpirationTimestamp,
    );
    // Order ids sort best price first on both sides: the price sits in the upper 64 bits and is
    // bit-inverted for bids. `limit_key` is the taker's limit price in that encoding.
    let (maker_book, limit_key) = if (is_ask) {
        (orderbook.borrow_mut_bids(), ((price ^ 0xFFFF_FFFF_FFFF_FFFF) as u128))
    } else {
        (orderbook.borrow_mut_asks(), (price as u128))
    };

    let mut last_matched_order_id = 0;
    let mut drop_last_matched = true;
    let mut reached_limit_price = false;
    // Makers that are canceled instead of filled (expired, self-trade, ...) cost gas without
    // reducing the taker size, so matching stops after too many of them.
    let mut unfilled_makers: u64 = 0;
    let mut too_many_unfilled_makers = false;
    let original_size = size;
    let mut leaf_ptr = maker_book.first_leaf_ptr();
    while (leaf_ptr != 0) {
        let leaf = maker_book.get_leaf_mut(leaf_ptr);
        leaf_ptr = leaf.next();
        let mut i = 0;
        let leaf_size = leaf.size();
        while (i < leaf_size) {
            let (maker_order_id, order) = leaf.elem_mut(i);
            if (maker_order_id >> 64 > limit_key) {
                reached_limit_price = true;
                break
            };
            last_matched_order_id = maker_order_id;
            let (filled_size, maker_order_done, maker_event, open_interest_delta) =
                process_fill_maker(
                    session_summary,
                    clearing_house_id,
                    maker_order_id,
                    order,
                    timestamp_ms,
                    collateral_price,
                    mark_price,
                    maker_fee,
                    liquidation_fee,
                    collateral_haircut,
                    funding_rate_long,
                    funding_rate_short,
                    open_interest,
                    max_open_interest_threshold,
                    max_open_interest_position_percent,
                    taker_account_id,
                    size,
                    taker_pending_cancelled,
                );
            size = size - filled_size;
            drop_last_matched = maker_order_done;
            let (maker_fees, integrator_fees) = events::maker_and_integrator_fees(&maker_event);
            hot_potato.total_fees =
                ifixed::add(hot_potato.total_fees, ifixed::add(maker_fees, integrator_fees));
            hot_potato.total_open_interest =
                ifixed::add(hot_potato.total_open_interest, open_interest_delta);
            maker_events.push_back(maker_event);
            if (size == 0) break;
            if (filled_size == 0) {
                unfilled_makers = unfilled_makers + 1;
                if (unfilled_makers == 200) {
                    too_many_unfilled_makers = true;
                    break
                }
            };
            i = i + 1;
        };
        if (reached_limit_price || too_many_unfilled_makers || size == 0) break;
    };
    if (order_type == 1) {
        assert!(size == 0, EFillOrKillOrderNotFilled)
    };
    if (order_type == 2) {
        assert!(size == original_size, EPostOnlyOrderWouldMatch)
    };
    // Immediate-or-cancel orders, and orders that hit the unfilled-maker cap, never rest.
    if (order_type == 3 || too_many_unfilled_makers) {
        size = 0;
    };

    if (last_matched_order_id > 0) {
        // Every order before the last matched one is gone; the last one stays on the book only
        // if it was partially filled.
        maker_book.batch_drop(last_matched_order_id, drop_last_matched);
        let best_price = if (maker_book.is_empty()) {
            option::none()
        } else {
            let best_order_id = maker_book.min_key();
            option::some(
                if (maker_side) ((best_order_id >> 64) as u64)
                else ((best_order_id >> 64) as u64) ^ 0xFFFF_FFFF_FFFF_FFFF,
            )
        };
        orderbook.set_best_price(maker_side, best_price)
    };

    let mut posted_order_id = option::none();
    if (size != 0) {
        let (integrator_id, integrator_fee_rate) = if (hot_potato.integrator_info.is_some()) {
            let info = hot_potato.integrator_info.borrow();
            (option::some(info.integrator_id()), info.integrator_fee_b9())
        } else {
            (option::none(), 0)
        };
        let order_id = orderbook.post_order(
            taker_account_id,
            side,
            size,
            price,
            client_order_id,
            reduce_only,
            expiration_timestamp_ms,
            hot_potato.integrator_info,
        );
        posted_order_id = option::some(order_id);
        events::emit_posted_order(
            ch_id,
            taker_account_id,
            order_id,
            client_order_id,
            size,
            reduce_only,
            expiration_timestamp_ms,
            integrator_id,
            integrator_fee_rate,
            mark_price,
            orderbook.book_price(),
        );
        let posted_base = ifixed::from_balance(size, 1_000_000_000);
        hot_potato.session_summary.posted_orders = hot_potato.session_summary.posted_orders + 1;
        if (side) {
            hot_potato.session_summary.base_posted_ask =
                ifixed::add(hot_potato.session_summary.base_posted_ask, posted_base)
        } else {
            hot_potato.session_summary.base_posted_bid =
                ifixed::add(hot_potato.session_summary.base_posted_bid, posted_base)
        }
    };
    (size, posted_order_id)
}

fun execute_market_order<T>(
    hot_potato: &mut SessionHotPotato<T>,
    side: bool,
    mut size: u64,
) {
    let market_params = &hot_potato.clearing_house.market_params;
    let market_state = &hot_potato.clearing_house.market_state;
    let maker_fee = market_params.maker_fee();
    let (liquidation_fee, _) = market_params.liquidation_fee_rates();
    let collateral_haircut = market_params.collateral_haircut();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let open_interest = market_state.open_interest();
    let (max_open_interest_threshold, max_open_interest_position_percent) =
        market_params.max_open_interest_position_params();
    let is_ask = side;
    // Makers rest on the opposite side of the book (ask = true, bid = false).
    let maker_side = if (is_ask) false else true;
    let (
        clearing_house_id,
        orderbook,
        session_summary,
        taker_pending_cancelled,
        maker_events,
        taker_account_id,
        timestamp_ms,
        collateral_price,
        mark_price,
    ) = (
        &mut hot_potato.clearing_house.id,
        &mut hot_potato.clearing_house.orderbook,
        &mut hot_potato.session_summary,
        &mut hot_potato.taker_pending_cancelled,
        &mut hot_potato.maker_events,
        hot_potato.account_id,
        hot_potato.timestamp_ms,
        hot_potato.collateral_price,
        hot_potato.mark_price,
    );
    let book_side = if (is_ask) orderbook.borrow_mut_bids() else orderbook.borrow_mut_asks();

    // Walk the maker side from the best price, one leaf of the ordered map at a time.
    let mut last_matched_order_id = 0;
    let mut drop_last_matched = true;
    let mut leaf_ptr = book_side.first_leaf_ptr();
    while (leaf_ptr != 0) {
        let leaf = book_side.get_leaf_mut(leaf_ptr);
        leaf_ptr = leaf.next();
        let mut i = 0;
        let leaf_size = leaf.size();
        while (i < leaf_size) {
            let (maker_order_id, order) = leaf.elem_mut(i);
            last_matched_order_id = maker_order_id;
            let (filled_size, maker_order_done, maker_event, open_interest_delta) =
                process_fill_maker(
                    session_summary,
                    clearing_house_id,
                    maker_order_id,
                    order,
                    timestamp_ms,
                    collateral_price,
                    mark_price,
                    maker_fee,
                    liquidation_fee,
                    collateral_haircut,
                    funding_rate_long,
                    funding_rate_short,
                    open_interest,
                    max_open_interest_threshold,
                    max_open_interest_position_percent,
                    taker_account_id,
                    size,
                    taker_pending_cancelled,
                );
            size = size - filled_size;
            drop_last_matched = maker_order_done;
            let (maker_fees, integrator_fees) = events::maker_and_integrator_fees(&maker_event);
            hot_potato.total_fees =
                ifixed::add(hot_potato.total_fees, ifixed::add(maker_fees, integrator_fees));
            hot_potato.total_open_interest =
                ifixed::add(hot_potato.total_open_interest, open_interest_delta);
            maker_events.push_back(maker_event);
            if (size == 0) break;
            i = i + 1;
        };
        if (size == 0) break;
    };
    assert!(size == 0, ENotEnoughLiquidity);

    if (last_matched_order_id > 0) {
        // Every order before the last matched one is gone; the last one stays on the book only
        // if it was partially filled.
        book_side.batch_drop(last_matched_order_id, drop_last_matched);
        let best_price = if (book_side.is_empty()) {
            option::none()
        } else {
            let best_order_id = book_side.min_key();
            // Order ids carry the price in their upper 64 bits, bit-inverted on the bid side.
            option::some(
                if (maker_side) ((best_order_id >> 64) as u64)
                else ((best_order_id >> 64) as u64) ^ 0xFFFF_FFFF_FFFF_FFFF,
            )
        };
        orderbook.set_best_price(maker_side, best_price)
    }
}

fun process_fill_maker(
    session_summary: &mut SessionSummary,
    clearing_house_id: &mut UID,
    maker_order_id: u128,
    order: &mut Order,
    timestamp_ms: u64,
    collateral_price: u256,
    mark_price: u256,
    maker_fee: u256,
    liquidation_fee: u256,
    collateral_haircut: u256,
    mkt_funding_rate_long: u256,
    mkt_funding_rate_short: u256,
    current_open_interest: u256,
    max_open_interest_threshold: u256,
    max_open_interest_position_percent: u256,
    taker_account_id: u64,
    taker_size_to_match: u64,
    taker_pending_cancelled: &mut bool,
): (u64, bool, FilledMakerOrder, u256) {
    let ch_id = clearing_house_id.to_inner();
    let (
        maker_account_id,
        client_order_id,
        order_size,
        reduce_only,
        expiration_timestamp_ms,
        integrator_info,
    ) = order.order_snapshot();
    let maker_position = borrow_mut_position_from_id(clearing_house_id, maker_account_id);
    settle_position_funding_and_emit(
        maker_position,
        collateral_price,
        mkt_funding_rate_long,
        mkt_funding_rate_short,
        &ch_id,
        maker_account_id,
    );
    let (maker_base_before, _) = maker_position.base_and_quote_amounts();
    // Ask order ids have the top bit clear.
    let is_ask = maker_order_id < 1 << 127;
    // Cancelation reasons: 4 = reduce-only clip, 5 = expired, 6 = self-trade,
    // 7 = fill would leave the maker in bad debt or above its open interest share.
    let mut cancel_reason: Option<u8> = option::none();
    let mut reported_cancel_reason = option::none();
    let mut fillable_size = if (reduce_only) {
        cancel_reason = option::some(4);
        // A reduce-only order only fills while it still reduces the maker position.
        let reduces_position = maker_base_before != 0
            && (
                (is_ask && !ifixed::is_neg(maker_base_before))
                    || (!is_ask && ifixed::is_neg(maker_base_before))
            );
        if (reduces_position) {
            let abs_base = ifixed::abs(maker_base_before);
            if (ifixed::greater_than_eq(abs_base, ifixed::from_balance(order_size, 1_000_000_000))) {
                order_size
            } else {
                ifixed::to_balance(abs_base, 1_000_000_000)
            }
        } else {
            0
        }
    } else {
        order_size
    };
    if (timestamp_ms >= expiration_timestamp_ms.destroy_with_default(0xFFFF_FFFF_FFFF_FFFF)) {
        fillable_size = 0;
        cancel_reason = option::some(5);
    } else if (taker_account_id == maker_account_id) {
        fillable_size = 0;
        cancel_reason = option::some(6);
    };

    let (
        base_filled,
        quote_filled,
        maker_pnl,
        maker_fees,
        integrator_id,
        integrator_fee_usd,
        maker_base_after,
    ) = if (fillable_size != 0 && taker_size_to_match != 0) {
        let fill_size = fillable_size.min(taker_size_to_match);
        let price = if (maker_order_id < 1 << 127) {
            ((maker_order_id >> 64) as u64)
        } else {
            ((maker_order_id >> 64) as u64) ^ 0xFFFF_FFFF_FFFF_FFFF
        };
        let (base_delta, quote_delta) = fill_base_and_quote_deltas(price, fill_size);
        // Past the open interest threshold a maker may not grow beyond its share of it.
        let open_interest_bound = ifixed::add(current_open_interest, base_delta);
        let max_maker_abs_base = if (
            ifixed::greater_than(open_interest_bound, max_open_interest_threshold)
        ) {
            option::some(ifixed::mul(open_interest_bound, max_open_interest_position_percent))
        } else {
            option::none()
        };
        let maker_fees = ifixed::mul_toward_zero(maker_fee, quote_delta);
        let (integrator_id, integrator_fee_usd) = if (integrator_info.is_some()) {
            let info = integrator_info.borrow();
            (option::some(info.integrator_id()), ifixed::mul(info.integrator_fee(), quote_delta))
        } else {
            (option::none(), 0)
        };
        let (applied, maker_pnl, maker_base_after) = maker_position
            .apply_maker_fill_or_restore_if_bad_debt(
                is_ask,
                base_delta,
                quote_delta,
                ifixed::add(maker_fees, integrator_fee_usd),
                liquidation_fee,
                collateral_price,
                mark_price,
                collateral_haircut,
                max_maker_abs_base,
            );
        if (applied) {
            (
                base_delta,
                quote_delta,
                maker_pnl,
                maker_fees,
                integrator_id,
                integrator_fee_usd,
                maker_base_after,
            )
        } else {
            fillable_size = 0;
            cancel_reason = option::some(7);
            (0, 0, 0, 0, option::none(), 0, maker_base_before)
        }
    } else {
        (0, 0, 0, 0, option::none(), 0, maker_base_before)
    };

    let mut canceled_size = 0;
    let mut maker_order_done = true;
    let filled_size = if (fillable_size == order_size) {
        if (taker_size_to_match >= fillable_size) {
            fillable_size
        } else {
            order.reduce_order_size(taker_size_to_match);
            maker_order_done = false;
            taker_size_to_match
        }
    } else if (taker_size_to_match >= fillable_size) {
        // The order is consumed: its fillable part fills and the rest is canceled.
        canceled_size = order_size - fillable_size;
        reported_cancel_reason = cancel_reason;
        maker_position.sub_from_pending_amount(
            is_ask,
            ifixed::from_balance(canceled_size, 1_000_000_000),
        );
        if (taker_account_id == maker_account_id && canceled_size != 0) {
            *taker_pending_cancelled = true
        };
        fillable_size
    } else {
        order.reduce_order_size(taker_size_to_match);
        maker_order_done = false;
        taker_size_to_match
    };
    if (maker_order_done) {
        maker_position.update_pending_orders(false, 1)
    };
    let open_interest_delta = if (filled_size != 0) {
        maker_position.sub_from_pending_amount(is_ask, base_filled);
        // Only long exposure counts towards open interest.
        let delta = ifixed::sub(
            ifixed::max(maker_base_after, 0),
            ifixed::max(maker_base_before, 0),
        );
        // A maker ask fills a taker bid and vice versa; a session takes one side only.
        if (is_ask) {
            assert!(session_summary.base_filled_ask == 0, ESameSessionOppositeSideTakerFill);
            session_summary.base_filled_bid =
                ifixed::add(session_summary.base_filled_bid, base_filled);
            session_summary.quote_filled_bid =
                ifixed::add(session_summary.quote_filled_bid, quote_filled)
        } else {
            assert!(session_summary.base_filled_bid == 0, ESameSessionOppositeSideTakerFill);
            session_summary.base_filled_ask =
                ifixed::add(session_summary.base_filled_ask, base_filled);
            session_summary.quote_filled_ask =
                ifixed::add(session_summary.quote_filled_ask, quote_filled)
        };
        delta
    } else {
        0
    };
    let maker_event = events::filled_maker_order(
        ch_id,
        maker_account_id,
        taker_account_id,
        maker_order_id,
        client_order_id,
        filled_size,
        order_size - filled_size - canceled_size,
        canceled_size,
        reported_cancel_reason,
        maker_pnl,
        maker_fees,
        mark_price,
        integrator_id,
        integrator_fee_usd,
    );
    (filled_size, maker_order_done, maker_event, open_interest_delta)
}

fun process_post(
    position: &mut Position,
    max_pending_orders: u64,
    session_summary: &SessionSummary,
) {
    if (session_summary.posted_orders == 0) return;
    position.update_pending_orders(true, session_summary.posted_orders);
    assert!(position.pending_order_count() <= max_pending_orders, EMaxPendingOrdersExceeded);
    if (session_summary.base_posted_ask != 0) {
        position.add_to_pending_amount(true, session_summary.base_posted_ask)
    };
    if (session_summary.base_posted_bid != 0) {
        position.add_to_pending_amount(false, session_summary.base_posted_bid)
    }
}

public(package) fun withdraw_free_collateral_to_account_balance<T>(
    clearing_house: &mut ClearingHouse<T>,
    account_balance: &mut Balance<T>,
    timestamp_ms: u64,
    collateral_price: u256,
    index_twap_price: u256,
    book_price: u256,
    account_id: u64,
    amount: Option<u64>,
): u64 {
    let ch_id = clearing_house.id.to_inner();
    let (market_params, market_state) = clearing_house.market_objects();
    let scaling_factor = market_params.scaling_factor();
    let collateral_haircut = market_params.collateral_haircut();
    let mark_price = market_state.calculate_mark_price(
        market_params,
        index_twap_price,
        book_price,
        timestamp_ms,
    );
    let market_imr = market_params.margin_ratio_initial();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let position = clearing_house.borrow_mut_position(account_id);
    let effective_imr = position.effective_initial_margin_ratio(market_imr);
    settle_position_funding_and_emit(
        position,
        collateral_price,
        funding_rate_long,
        funding_rate_short,
        &ch_id,
        account_id,
    );
    let free_collateral = position.compute_free_collateral(
        collateral_price,
        mark_price,
        effective_imr,
        collateral_haircut,
    );
    let free_collateral_amount = ifixed::to_balance(free_collateral, scaling_factor);
    // Withdraw the requested amount, or all the free collateral when none is given.
    let withdrawn;
    let withdrawn_fixed;
    if (amount.is_some()) {
        let requested = amount.destroy_some();
        assert!(requested != 0, EDepositOrWithdrawAmountZero);
        assert!(free_collateral_amount >= requested, EInsufficientFreeCollateral);
        withdrawn = requested;
        withdrawn_fixed = ifixed::from_balance(requested, scaling_factor);
    } else {
        if (free_collateral == 0) return 0;
        withdrawn = free_collateral_amount;
        withdrawn_fixed = free_collateral;
    };
    position.sub_from_collateral(withdrawn_fixed);
    withdraw_vault_collateral(clearing_house.borrow_mut_market_vault(), account_balance, withdrawn);
    withdrawn
}

fun withdraw_vault_collateral<T>(
    vault: &mut Vault<T>,
    account_balance: &mut Balance<T>,
    amount: u64,
) {
    assert!(vault.collateral_balance.value() >= amount, EInsufficientVaultCollateral);
    let collateral = vault.collateral_balance.split(amount);
    account_balance.join(collateral);
}

fun execute_liquidation<T>(
    hot_potato: &mut SessionHotPotato<T>,
    liqee_account_id: u64,
    liqee_base_ask_cancel: u128,
    liqee_base_bid_cancel: u128,
    liqee_pending_orders_cancel: u64,
) {
    let ch_id = &hot_potato.clearing_house.id.to_inner();
    settle_liquidated_position(
        hot_potato,
        liqee_account_id,
        liqee_base_ask_cancel,
        liqee_base_bid_cancel,
        liqee_pending_orders_cancel,
        ch_id,
    );
    if (hot_potato.session_summary.bad_debt != 0) {
        handle_bad_debt(
            &mut hot_potato.clearing_house,
            hot_potato.session_summary.bad_debt,
            hot_potato.mark_price,
            hot_potato.collateral_price,
            hot_potato.session_summary.is_liqee_long,
            ch_id,
            option::none(),
        )
    }
}

fun settle_liquidated_position<T>(
    hot_potato: &mut SessionHotPotato<T>,
    liqee_account_id: u64,
    liqee_base_ask_cancel: u128,
    liqee_base_bid_cancel: u128,
    liqee_pending_orders_cancel: u64,
    ch_id: &ID,
) {
    let (market_params, market_state) = hot_potato.clearing_house.market_objects();
    let (liquidation_fee, insurance_fund_fee) = market_params.liquidation_fee_rates();
    let lot_size = market_params.lot_size();
    let scaling_factor = market_params.scaling_factor();
    let market_imr = market_params.margin_ratio_initial();
    let market_mmr = market_params.margin_ratio_maintenance();
    let collateral_haircut = market_params.collateral_haircut();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let mark_price = hot_potato.mark_price;
    let position = hot_potato.clearing_house.borrow_mut_position(liqee_account_id);
    settle_position_funding_and_emit(
        position,
        hot_potato.collateral_price,
        funding_rate_long,
        funding_rate_short,
        ch_id,
        liqee_account_id,
    );
    let (margin, min_margin) = position.compute_margin_and_requirement(
        hot_potato.collateral_price,
        mark_price,
        market_mmr,
        collateral_haircut,
    );
    assert!(ifixed::less_than(margin, min_margin), EPositionAboveMmr);

    // The liquidator must have force-canceled every pending order of the liqee.
    position.sub_from_pending_amount(
        true,
        ifixed::from_u128balance(liqee_base_ask_cancel, 1_000_000_000),
    );
    position.sub_from_pending_amount(
        false,
        ifixed::from_u128balance(liqee_base_bid_cancel, 1_000_000_000),
    );
    position.update_pending_orders(false, liqee_pending_orders_cancel);
    let (pending_asks, pending_bids) = position.pending_base_amounts_by_side();
    let pending_orders = position.pending_order_count();
    assert!(
        pending_asks == 0 && pending_bids == 0 && pending_orders == 0,
        EInvalidForceCancelIds,
    );

    let (size_to_liquidate, cancel_orders_only) = compute_liquidation_size_and_mode(
        position,
        hot_potato.collateral_price,
        mark_price,
        market_imr,
        liquidation_fee,
        insurance_fund_fee,
        collateral_haircut,
    );
    let (base, _) = position.base_and_quote_amounts();
    let size = if (cancel_orders_only) {
        0
    } else {
        clip_size_to_liquidate(size_to_liquidate, base, lot_size)
    };
    let mut outcome = reduce_liquidated_position(
        position,
        size,
        mark_price,
        hot_potato.collateral_price,
        insurance_fund_fee,
        liquidation_fee,
        market_imr,
        collateral_haircut,
    );
    // A partial liquidation must restore the initial margin; otherwise the rest of the
    // position is liquidated too.
    if (ifixed::less_than(outcome.margin, outcome.min_margin)) {
        let (base_left, _) = position.base_and_quote_amounts();
        let rest = reduce_liquidated_position(
            position,
            ifixed::to_u128balance(ifixed::abs(base_left), 1_000_000_000),
            mark_price,
            hot_potato.collateral_price,
            insurance_fund_fee,
            liquidation_fee,
            market_imr,
            collateral_haircut,
        );
        outcome.add(&rest);
    };
    if (outcome.insurance_fund_fees != 0) {
        transfer_from_vault_to_insurance_fund(
            hot_potato.clearing_house.borrow_mut_market_vault(),
            ifixed::div(outcome.insurance_fund_fees, hot_potato.collateral_price),
            scaling_factor,
        )
    };
    events::emit_liquidated_position(
        *ch_id,
        liqee_account_id,
        hot_potato.account_id,
        outcome.is_long,
        outcome.base_liquidated,
        outcome.quote_liquidated,
        outcome.pnl,
        outcome.liquidation_fees,
        outcome.insurance_fund_fees,
        outcome.bad_debt,
        mark_price,
    );
    // The liquidator takes over the position (and the fees) when the session ends.
    hot_potato.total_open_interest =
        ifixed::add(hot_potato.total_open_interest, outcome.open_interest_delta);
    hot_potato.liqee_account_id = option::some(liqee_account_id);
    hot_potato.liquidator_fees = outcome.liquidation_fees;
    hot_potato.session_summary.base_liquidated = outcome.base_liquidated;
    hot_potato.session_summary.quote_liquidated = outcome.quote_liquidated;
    hot_potato.session_summary.is_liqee_long = outcome.is_long;
    hot_potato.session_summary.bad_debt = outcome.bad_debt
}

/// Folds a follow-up liquidation step into this one: the amounts add up and the margin figures
/// are those after the last step.
fun add(outcome: &mut LiquidationOutcome, rest: &LiquidationOutcome) {
    outcome.margin = rest.margin;
    outcome.min_margin = rest.min_margin;
    outcome.base_liquidated = ifixed::add(outcome.base_liquidated, rest.base_liquidated);
    outcome.quote_liquidated = ifixed::add(outcome.quote_liquidated, rest.quote_liquidated);
    outcome.pnl = ifixed::add(outcome.pnl, rest.pnl);
    outcome.liquidation_fees = ifixed::add(outcome.liquidation_fees, rest.liquidation_fees);
    outcome.insurance_fund_fees =
        ifixed::add(outcome.insurance_fund_fees, rest.insurance_fund_fees);
    outcome.bad_debt = ifixed::add(outcome.bad_debt, rest.bad_debt);
    outcome.open_interest_delta =
        ifixed::add(outcome.open_interest_delta, rest.open_interest_delta);
}

public(package) fun reduce_liquidated_position(
    position: &mut Position,
    size_to_liquidate: u128,
    mark_price: u256,
    collateral_price: u256,
    insurance_fund_fee: u256,
    liquidation_fee: u256,
    margin_ratio_required: u256,
    collateral_haircut: u256
): LiquidationOutcome {
    let (base_before, _) = position.base_and_quote_amounts();
    let base_liquidated = ifixed::from_u128balance(size_to_liquidate, 1_000_000_000);
    let quote_liquidated = ifixed::mul(base_liquidated, mark_price);
    let is_long = !ifixed::is_neg(base_before);
    // The position is closed at the mark price by trading against the liquidator.
    let (pnl, open_interest_delta, base_after) = if (size_to_liquidate != 0) {
        let (pnl, base_after) = position.add_base_to_position(
            is_long,
            base_liquidated,
            quote_liquidated,
        );
        let open_interest_delta = if (is_long) ifixed::neg(base_liquidated) else 0;
        (pnl, open_interest_delta, base_after)
    } else {
        (0, 0, base_before)
    };
    let insurance_fund_fees = ifixed::mul(insurance_fund_fee, quote_liquidated);
    let liquidation_fees = ifixed::mul(liquidation_fee, quote_liquidated);
    let pnl_after_liquidation_fees = ifixed::sub(pnl, liquidation_fees);
    let collateral_after = ifixed::add(
        position.collateral(),
        ifixed::div(pnl_after_liquidation_fees, collateral_price),
    );
    let collateral_after_usd = ifixed::mul(collateral_after, collateral_price);
    let account_value = ifixed::add(collateral_after_usd, position.unrealized_pnl(mark_price));
    let mut bad_debt = 0;
    // A fully closed position left with negative collateral is bad debt.
    let has_bad_debt = base_after == 0 && ifixed::is_neg(collateral_after);
    // The insurance fund fee is only charged out of what the account still has.
    let fee_capacity = if (
        !has_bad_debt && ifixed::greater_than(account_value, 0) && !ifixed::is_neg(collateral_after)
    ) {
        ifixed::min(collateral_after_usd, account_value)
    } else {
        0
    };
    let insurance_fund_fees_paid = if (ifixed::less_than_eq(insurance_fund_fees, fee_capacity)) {
        insurance_fund_fees
    } else {
        fee_capacity
    };
    let collateral_change_usd = ifixed::sub(pnl_after_liquidation_fees, insurance_fund_fees_paid);
    position.add_to_collateral_usd(collateral_change_usd, collateral_price);
    if (has_bad_debt) {
        bad_debt = position.reset_collateral();
    };
    let (margin, min_margin) = position.compute_margin_and_requirement(
        collateral_price,
        mark_price,
        margin_ratio_required,
        collateral_haircut,
    );
    LiquidationOutcome {
        margin,
        min_margin,
        is_long,
        base_liquidated,
        quote_liquidated,
        pnl,
        liquidation_fees,
        insurance_fund_fees: insurance_fund_fees_paid,
        bad_debt,
        open_interest_delta,
    }
}

public(package) fun force_cancel_orders(
    orderbook: &mut Orderbook,
    account_id: u64,
    order_ids: &vector<u128>,
    ch_id: ID,
    cancelation_reason: u8,
): (u128, u128, u64) {
    let mut i = 0;
    let mut base_ask_canceled = 0;
    let mut base_bid_canceled = 0;
    let mut orders_canceled = 0;
    let order_count = order_ids.length();
    while (i < order_count) {
        let order_id = order_ids[i];
        let (canceled, size, client_order_id) =
            orderbook.try_cancel_limit_order(account_id, order_id);
        if (canceled) {
            orders_canceled = orders_canceled + 1;
            events::emit_canceled_order(
                ch_id,
                account_id,
                order_id,
                client_order_id,
                size,
                cancelation_reason,
                orderbook.book_price(),
            );
            if (order_id < 1 << 127) {
                base_ask_canceled = base_ask_canceled + (size as u128);
            } else {
                base_bid_canceled = base_bid_canceled + (size as u128);
            }
        };
        i = i + 1;
    };
    (base_ask_canceled, base_bid_canceled, orders_canceled)
}

fun transfer_from_vault_to_insurance_fund<T>(
    vault: &mut Vault<T>,
    amount: u256,
    scaling_factor: u256
) {
    let balance_amount = ifixed::to_balance(amount, scaling_factor);
    assert!(vault.collateral_balance.value() >= balance_amount, EInsufficientVaultCollateral);
    let funds = vault.collateral_balance.split(balance_amount);
    vault.insurance_fund_balance.join(funds);
}

fun transfer_from_insurance_fund_to_vault<T>(
    vault: &mut Vault<T>,
    amount: u256,
    scaling_factor: u256
) {
    // Round up so the vault never ends up short of `amount`.
    let rounded_down = ifixed::to_balance(amount, scaling_factor);
    let balance_amount = if (ifixed::from_balance(rounded_down, scaling_factor) == amount) {
        rounded_down
    } else {
        rounded_down + 1
    };
    let funds = vault.insurance_fund_balance.split(balance_amount);
    vault.collateral_balance.join(funds);
}

fun handle_bad_debt<T>(
    clearing_house: &mut ClearingHouse<T>,
    bad_debt: u256,
    mark_price: u256,
    collateral_price: u256,
    is_liqee_long: bool,
    ch_id: &ID,
    socialization_open_interest: Option<u256>,
) {
    let scaling_factor = clearing_house.market_params.scaling_factor();
    let (max_bad_debt, max_socialize_losses_mr_decrease) =
        clearing_house.market_params.max_bad_debt_thresholds();
    let vault = clearing_house.borrow_mut_market_vault();
    let insurance_fund = ifixed::from_balance(vault.insurance_fund_balance.value(), scaling_factor);
    if (ifixed::greater_than_eq(insurance_fund, bad_debt)) {
        transfer_from_insurance_fund_to_vault(vault, bad_debt, scaling_factor)
    } else {
        // The insurance fund pays what it can and the rest is socialized over open interest.
        let uncovered_usd = ifixed::mul(ifixed::sub(bad_debt, insurance_fund), collateral_price);
        transfer_from_insurance_fund_to_vault(vault, insurance_fund, scaling_factor);
        try_socialize_bad_debt(
            &mut clearing_house.market_state,
            mark_price,
            is_liqee_long,
            uncovered_usd,
            max_bad_debt,
            max_socialize_losses_mr_decrease,
            ch_id,
            socialization_open_interest,
        )
    }
}

fun try_socialize_bad_debt(
    market_state: &mut MarketState,
    mark_price: u256,
    is_liqee_long: bool,
    amount_to_socialize: u256,
    max_bad_debt: u256,
    max_socialize_losses_mr_decrease: u256,
    ch_id: &ID,
    socialization_open_interest: Option<u256>,
) {
    let open_interest;
    if (socialization_open_interest.is_some()) {
        open_interest = socialization_open_interest.destroy_some();
    } else {
        open_interest = market_state.open_interest();
    };
    assert!(open_interest != 0, ENoOpenInterestToSocializeBadDebt);
    let loss_per_base = ifixed::div_up(amount_to_socialize, open_interest);
    assert!(
        ifixed::less_than_eq(amount_to_socialize, max_bad_debt),
        EBadDebtNotionalAboveThreshold,
    );
    // Relative to the mark price, the loss per unit of base is the margin ratio drop it causes.
    assert!(
        ifixed::less_than_eq(
            ifixed::div(loss_per_base, mark_price),
            max_socialize_losses_mr_decrease,
        ),
        EBadDebtSocializationAboveThreshold,
    );
    // The loss is charged to the counterparties of the liquidated side through funding.
    market_state.add_bad_debt_to_market(ch_id, !is_liqee_long, amount_to_socialize, loss_per_base)
}

public fun compute_liquidation_size_and_mode(
    liqee_position: &Position,
    collateral_price: u256,
    mark_price: u256,
    market_imr: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    collateral_haircut: u256
): (u256, bool) {
    let (base, quote) = liqee_position.base_and_quote_amounts();
    let collateral = liqee_position.collateral();
    let abs_base = ifixed::abs(base);
    let mi_pm_abs_b = ifixed::mul(ifixed::mul(abs_base, mark_price), market_imr);
    let (margin, min_margin) = liqee_position.compute_margin_and_requirement(
        collateral_price,
        mark_price,
        market_imr,
        collateral_haircut,
    );
    if (collateral_haircut == 0) {
        let (size, cancel_orders_only) = compute_liquidation_size_no_haircut(
            base,
            quote,
            collateral,
            abs_base,
            collateral_price,
            mark_price,
            liquidation_fee,
            insurance_fund_fee,
            mi_pm_abs_b,
            margin,
            min_margin,
        );
        return (size, cancel_orders_only)
    };
    let (size, cancel_orders_only) = compute_liquidation_size_with_haircut(
        base,
        quote,
        collateral,
        abs_base,
        collateral_price,
        mark_price,
        liquidation_fee,
        insurance_fund_fee,
        collateral_haircut,
        mi_pm_abs_b,
        margin,
        min_margin,
    );
    (size, cancel_orders_only)
}

// Liquidating a fraction `alpha` of the position removes `alpha * mi_pm_abs_b` of initial margin
// requirement and costs `alpha * (fees * notional)`, so the smallest `alpha` that restores the
// initial margin is `shortfall / (mi_pm_abs_b - fees * notional)`, rounded up.
fun compute_liquidation_size_no_haircut(
    b: u256,
    q: u256,
    c: u256,
    abs_b: u256,
    collateral_price: u256,
    mark_price: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    mi_pm_abs_b: u256,
    margin_before: u256,
    min_margin_before: u256,
): (u256, bool) {
    if (ifixed::greater_than_eq(margin_before, min_margin_before)) return (0, true);
    if (ifixed::less_than_eq(margin_before, 0)) return (abs_b, false);
    let upnl = ifixed::sub(ifixed::mul(mark_price, b), q);
    let collateral_usd = ifixed::mul(collateral_price, c);
    let notional = ifixed::mul(mark_price, abs_b);
    let cushion = liquidation_collateral_rounding_cushion(collateral_price);
    let shortfall = ifixed::sub(
        ifixed::add(mi_pm_abs_b, cushion),
        ifixed::add(upnl, collateral_usd),
    );
    let (fee_waived, waived_alpha) = waived_fee_liquidation_alpha(
        shortfall,
        mi_pm_abs_b,
        collateral_usd,
        upnl,
        ifixed::mul(liquidation_fee, notional),
    );
    if (fee_waived) return (ifixed::mul(waived_alpha, abs_b), false);
    let margin_freed_per_alpha = ifixed::sub(
        mi_pm_abs_b,
        ifixed::mul(ifixed::add(liquidation_fee, insurance_fund_fee), notional),
    );
    let alpha = ifixed::div_up(shortfall, margin_freed_per_alpha);
    if (!valid_liquidation_alpha(alpha)) return (abs_b, false);
    (ifixed::mul(alpha, abs_b), false)
}

// When the account cannot even pay the liquidation fee on the realized pnl, the insurance fund
// fee is waived and `alpha` only accounts for the liquidation fee.
fun waived_fee_liquidation_alpha(
    num: u256,
    mi_pm_abs_b: u256,
    collateral_usd: u256,
    upnl: u256,
    liq_fee_notional: u256,
): (bool, u256) {
    let margin_freed_per_alpha = ifixed::sub(mi_pm_abs_b, liq_fee_notional);
    if (!ifixed::greater_than(margin_freed_per_alpha, 0)) return (false, 0);
    let alpha = ifixed::div_up(num, margin_freed_per_alpha);
    let collateral_after = ifixed::add(
        collateral_usd,
        ifixed::mul(alpha, ifixed::sub(upnl, liq_fee_notional)),
    );
    (valid_liquidation_alpha(alpha) && !ifixed::greater_than(collateral_after, 0), alpha)
}

// Same approach as `compute_liquidation_size_no_haircut` with the haircut applied to positive
// collateral; when both the waived-fee and the haircut `alpha` are valid, the smaller one wins.
fun compute_liquidation_size_with_haircut(
    b: u256,
    q: u256,
    c: u256,
    abs_b: u256,
    collateral_price: u256,
    mark_price: u256,
    liquidation_fee: u256,
    insurance_fund_fee: u256,
    collateral_haircut: u256,
    mi_pm_abs_b: u256,
    margin_before: u256,
    min_margin_before: u256,
): (u256, bool) {
    let haircut_complement = ifixed::sub(1_000_000_000_000_000_000, collateral_haircut);
    let upnl = ifixed::sub(ifixed::mul(mark_price, b), q);
    let fees_notional = ifixed::mul(
        ifixed::add(liquidation_fee, insurance_fund_fee),
        ifixed::mul(mark_price, abs_b),
    );
    let collateral_usd = ifixed::mul(collateral_price, c);
    let account_value = ifixed::add(collateral_usd, upnl);
    let cushion = liquidation_collateral_rounding_cushion(collateral_price);
    if (ifixed::greater_than_eq(margin_before, min_margin_before)) return (0, true);
    if (ifixed::less_than_eq(account_value, 0)) return (abs_b, false);
    let upnl_after_fees = ifixed::sub(upnl, fees_notional);
    let mut alpha = 0;
    let mut found = false;
    let (fee_waived, waived_alpha) = waived_fee_liquidation_alpha(
        ifixed::sub(ifixed::add(mi_pm_abs_b, cushion), account_value),
        mi_pm_abs_b,
        collateral_usd,
        upnl,
        ifixed::mul(liquidation_fee, ifixed::mul(mark_price, abs_b)),
    );
    if (fee_waived) {
        alpha = waived_alpha;
        found = true;
    };
    let margin_freed_per_alpha = ifixed::sub(
        ifixed::sub(mi_pm_abs_b, ifixed::mul(collateral_haircut, upnl)),
        ifixed::mul(fees_notional, haircut_complement),
    );
    if (ifixed::greater_than(margin_freed_per_alpha, 0)) {
        let haircut_alpha = ifixed::div_up(
            ifixed::sub(
                ifixed::add(mi_pm_abs_b, cushion),
                ifixed::add(upnl, ifixed::mul(collateral_usd, haircut_complement)),
            ),
            margin_freed_per_alpha,
        );
        let collateral_after =
            ifixed::add(collateral_usd, ifixed::mul(haircut_alpha, upnl_after_fees));
        // Only valid while the collateral stays non-negative (the haircut applies), and only if
        // it liquidates less than the waived-fee alternative.
        if (
            valid_liquidation_alpha(haircut_alpha)
                && !ifixed::is_neg(collateral_after)
                && (!found || ifixed::less_than(haircut_alpha, alpha))
        ) {
            alpha = haircut_alpha;
            found = true;
        }
    };
    if (!found) return (abs_b, false);
    (ifixed::mul(alpha, abs_b), false)
}

// USD value of one fixed-point unit of collateral, rounded up.
fun liquidation_collateral_rounding_cushion(collateral_price: u256): u256 {
    (collateral_price + 999_999_999_999_999_999) / 1_000_000_000_000_000_000
}

fun valid_liquidation_alpha(alpha: u256): bool {
    !ifixed::less_than(alpha, 0) && !ifixed::greater_than(alpha, 1_000_000_000_000_000_000)
}

fun collateral_for_margin_increase(
    collateral: u256,
    collateral_price: u256,
    collateral_haircut: u256,
    margin_increase: u256,
): u256 {
    if (collateral_haircut == 0) return ifixed::div_up(margin_increase, collateral_price);
    let collateral_usd = ifixed::mul(collateral, collateral_price);
    let haircut_complement = ifixed::sub(1_000_000_000_000_000_000, collateral_haircut);
    // Negative collateral is not haircut: the part that repays it counts in full.
    let collateral_usd_needed = if (ifixed::is_neg(collateral_usd)) {
        let debt_usd = ifixed::neg(collateral_usd);
        if (ifixed::less_than_eq(margin_increase, debt_usd)) {
            margin_increase
        } else {
            ifixed::add(
                debt_usd,
                ifixed::div_up(ifixed::sub(margin_increase, debt_usd), haircut_complement),
            )
        }
    } else {
        ifixed::div_up(margin_increase, haircut_complement)
    };
    ifixed::div_up(collateral_usd_needed, collateral_price)
}

public fun clip_size_to_liquidate(
    size_to_liquidate: u256,
    position_base_amount: u256,
    lot_size: u64
): u128 {
    // One extra base unit absorbs the rounding down of the fixed-point size.
    let size = ifixed::to_u128balance(ifixed::abs(size_to_liquidate), 1_000_000_000) + 1;
    let position_size = ifixed::to_u128balance(ifixed::abs(position_base_amount), 1_000_000_000);
    if (lot_size != 1) {
        (size.div_ceil(lot_size as u128) * (lot_size as u128)).min(position_size)
    } else {
        size.min(position_size)
    }
}

fun collateral_symbol<T>(): String {
    type_name::with_defining_ids<T>().into_string().into_bytes().to_string()
}

public fun fill_base_and_quote_deltas(
    price: u64,
    size: u64,
): (u256, u256) {
    let base = ifixed::from_balance(size, 1_000_000_000);
    // A 9-decimal size times a 9-decimal price is already an 18-decimal fixed-point value.
    let quote = (size as u256) * (price as u256);
    (base, quote)
}

fun deallocate_collateral_<T, ADMIN_OR_ASSISTANT>(
    clearing_house: &mut ClearingHouse<T>,
    cap: &AuthorityCap<ACCOUNT, ADMIN_OR_ASSISTANT>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount: Option<u64>,
    clock: &Clock,
): u64 {
    assert_package_version(clearing_house);
    assert_market_is_not_paused(clearing_house);
    account.assert_authority_cap_is_valid(cap);
    deallocate_collateral_internal(
        clearing_house,
        account,
        base_oracle,
        collateral_oracle,
        amount,
        clock,
    )
}

public(package) fun deallocate_collateral_internal<T>(
    clearing_house: &mut ClearingHouse<T>,
    account: &mut Account<T>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount: Option<u64>,
    clock: &Clock,
): u64 {
    let account_id = account.account_id();
    let ch_id = clearing_house.id.to_inner();
    let now = clock.timestamp_ms();
    let market_params = clearing_house.market_params();
    let collateral_price = market_params.collateral_oracle_price(collateral_oracle, clock);
    let (index_price, index_twap_price) =
        market_params.base_oracle_price_and_twap_price(base_oracle, clock);
    market_params.assert_index_twap_divergence_within_limit(index_price, index_twap_price);
    let book_price = clearing_house.orderbook().book_price_or_index(index_price);
    market::try_update_fundings_and_twaps(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        now,
        index_price,
        book_price,
        &ch_id,
    );
    let withdrawn = withdraw_free_collateral_to_account_balance(
        clearing_house,
        account.borrow_mut_collateral(),
        now,
        collateral_price,
        index_twap_price,
        book_price,
        account_id,
        amount,
    );
    if (withdrawn != 0) {
        events::emit_deallocated_collateral(ch_id, account_id, withdrawn)
    };
    withdrawn
}

public(package) fun start_session_<T>(
    mut clearing_house: ClearingHouse<T>,
    account_id: u64,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    uses_priority_gas_price: bool,
    integrator_info: Option<IntegratorInfo>,
    clock: &Clock,
): SessionHotPotato<T> {
    let ch_id = clearing_house.id.to_inner();
    let now = clock.timestamp_ms();
    let (collateral_price, index_price, index_twap_price) = {
        let market_params = clearing_house.market_params();
        let collateral_price = market_params.collateral_oracle_price(collateral_oracle, clock);
        let (index_price, index_twap_price) =
            market_params.base_oracle_price_and_twap_price(base_oracle, clock);
        market_params.assert_index_twap_divergence_within_limit(index_price, index_twap_price);
        (collateral_price, index_price, index_twap_price)
    };
    let book_price = clearing_house.orderbook.book_price_or_index(index_price);
    market::try_update_fundings_and_twaps(
        &clearing_house.market_params,
        &mut clearing_house.market_state,
        now,
        index_price,
        book_price,
        &ch_id,
    );
    let (market_params, market_state) = clearing_house.market_objects();
    let market_imr = market_params.margin_ratio_initial();
    let collateral_haircut = market_params.collateral_haircut();
    let (funding_rate_long, funding_rate_short) = market_state.cum_funding_rates();
    let mark_price = market_state.calculate_mark_price(
        market_params,
        index_twap_price,
        book_price,
        now,
    );
    let position = clearing_house.borrow_mut_position(account_id);
    let effective_imr = position.effective_initial_margin_ratio(market_imr);
    let (position_base_before, _) = position.base_and_quote_amounts();
    settle_position_funding_and_emit(
        position,
        collateral_price,
        funding_rate_long,
        funding_rate_short,
        &ch_id,
        account_id,
    );
    // The margin at the start of the session is what `end_session_` checks the result against.
    let (margin_before, min_margin_before) = position.compute_margin_and_requirement(
        collateral_price,
        mark_price,
        effective_imr,
        collateral_haircut,
    );
    SessionHotPotato {
        clearing_house,
        account_id,
        timestamp_ms: now,
        collateral_price,
        mark_price,
        uses_priority_gas_price,
        margin_before,
        min_margin_before,
        position_base_before,
        total_open_interest: 0,
        total_fees: 0,
        taker_pending_cancelled: false,
        maker_events: vector[],
        integrator_info,
        liqee_account_id: option::none(),
        liquidator_fees: 0,
        session_summary: create_session_summary(),
    }
}

fun cancel_orders_<T>(
    clearing_house: &mut ClearingHouse<T>,
    account_id: u64,
    order_ids: &vector<u128>,
    cancelation_reason: u8,
) {
    let order_count = order_ids.length();
    assert!(order_count != 0, EEmptyCancelOrderIds);
    let ch_id = clearing_house.id.to_inner();
    let orderbook = clearing_house.borrow_mut_orderbook();
    let mut base_ask_canceled = 0;
    let mut base_bid_canceled = 0;
    order_ids.do_ref!(|order_id| {
        let order_id = *order_id;
        let (size, client_order_id) = orderbook.cancel_limit_order(account_id, order_id);
        if (order_id < 1 << 127) {
            base_ask_canceled = base_ask_canceled + (size as u128);
        } else {
            base_bid_canceled = base_bid_canceled + (size as u128);
        };
        events::emit_canceled_order(
            ch_id,
            account_id,
            order_id,
            client_order_id,
            size,
            cancelation_reason,
            orderbook.book_price(),
        );
    });
    let base_ask_canceled = ifixed::from_u128balance(base_ask_canceled, 1_000_000_000);
    let base_bid_canceled = ifixed::from_u128balance(base_bid_canceled, 1_000_000_000);
    let position = clearing_house.borrow_mut_position(account_id);
    position.sub_from_pending_amount(true, base_ask_canceled);
    position.sub_from_pending_amount(false, base_bid_canceled);
    position.update_pending_orders(false, order_count)
}

fun try_cancel_orders_<T>(
    clearing_house: &mut ClearingHouse<T>,
    account_id: u64,
    order_ids: &vector<u128>,
    cancel_stale_at: Option<u64>,
    account_base: u256,
): vector<bool> {
    let mut results = vector[];
    let ch_id = clearing_house.id.to_inner();
    let orderbook = clearing_house.borrow_mut_orderbook();
    let mut base_ask_canceled = 0;
    let mut base_bid_canceled = 0;
    let mut orders_canceled = 0;
    order_ids.do_ref!(|order_id| {
        let order_id = *order_id;
        // Stale mode only cancels expired orders (reason 5) and reduce-only orders that would
        // no longer reduce the position (reason 4).
        let (canceled, size, client_order_id, cancelation_reason) = if (cancel_stale_at.is_some()) {
            let (canceled, expired, size, client_order_id) = orderbook
                .try_cancel_stale_limit_order(
                    account_id,
                    order_id,
                    *cancel_stale_at.borrow(),
                    account_base,
                );
            (canceled, size, client_order_id, if (expired) 5 else 4)
        } else {
            let (canceled, size, client_order_id) =
                orderbook.try_cancel_limit_order(account_id, order_id);
            (canceled, size, client_order_id, 0)
        };
        results.push_back(canceled);
        if (canceled) {
            orders_canceled = orders_canceled + 1;
            if (order_id < 1 << 127) {
                base_ask_canceled = base_ask_canceled + (size as u128);
            } else {
                base_bid_canceled = base_bid_canceled + (size as u128);
            };
            events::emit_canceled_order(
                ch_id,
                account_id,
                order_id,
                client_order_id,
                size,
                cancelation_reason,
                orderbook.book_price(),
            )
        };
    });
    if (orders_canceled != 0) {
        let base_ask_canceled = ifixed::from_u128balance(base_ask_canceled, 1_000_000_000);
        let base_bid_canceled = ifixed::from_u128balance(base_bid_canceled, 1_000_000_000);
        let position = clearing_house.borrow_mut_position(account_id);
        position.sub_from_pending_amount(true, base_ask_canceled);
        position.sub_from_pending_amount(false, base_bid_canceled);
        position.update_pending_orders(false, orders_canceled)
    };
    results
}

fun create_clearing_house_<T, VendorKey, ADMIN_OR_ASSISTANT>(
    orderbook: Orderbook,
    cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    registry: &mut Registry,
    clock: &Clock,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_source_id: u16,
    collateral_source_id: u16,
    decimals: u64,
    params: &MarketCreationParams,
    ctx: &mut TxContext,
): ClearingHouse<T> {
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    assert!(base_oracle.contains(base_source_id), EPriceFeedSourceDoesNotExist);
    assert!(collateral_oracle.contains(collateral_source_id), EPriceFeedSourceDoesNotExist);
    let base_storage_id = base_oracle.storage_id();
    let collateral_storage_id = collateral_oracle.storage_id();
    let vault = Vault<T> {
        collateral_balance: balance::zero(),
        insurance_fund_balance: balance::zero(),
    };
    let (market_params, market_state) = market::create_market_objects(
        registry.config(),
        clock,
        base_storage_id,
        collateral_storage_id,
        base_source_id,
        collateral_source_id,
        params,
        (ifixed::decimal_scalar_from_decimals(decimals) as u256),
    );
    let id = object::new(ctx);
    let version = registry.version();
    let mut clearing_house = ClearingHouse {
        id,
        version,
        paused: 0,
        market_params,
        market_state,
        orderbook,
    };
    df::add(&mut clearing_house.id, keys::market_vault(), vault);
    let ch_id = clearing_house.id.to_inner();
    let (maker_fee, taker_fee) = market_params.maker_taker_fees();
    let (liquidation_fee, insurance_fund_fee) = market_params.liquidation_fee_rates();
    let (funding_frequency_ms, funding_period_ms) = market_params.funding_params();
    let (premium_twap_frequency_ms, premium_twap_period_ms) = market_params.premium_twap_params();
    let (spread_twap_frequency_ms, spread_twap_period_ms) = market_params.spread_twap_params();
    let (max_bad_debt, max_socialize_losses_mr_decrease) = market_params.max_bad_debt_thresholds();
    events::emit_created_clearing_house(
        ch_id,
        collateral_symbol<T>(),
        decimals,
        market_params.margin_ratio_initial(),
        market_params.margin_ratio_maintenance(),
        base_storage_id,
        base_source_id,
        collateral_storage_id,
        collateral_source_id,
        funding_frequency_ms,
        funding_period_ms,
        premium_twap_frequency_ms,
        premium_twap_period_ms,
        spread_twap_frequency_ms,
        spread_twap_period_ms,
        maker_fee,
        taker_fee,
        liquidation_fee,
        insurance_fund_fee,
        market_params.lot_size(),
        market_params.tick_size(),
        max_bad_debt,
        max_socialize_losses_mr_decrease,
        market_params.priority_taker_fee(),
    );
    let vendor_clearing_houses: &mut vector<ID> = df::borrow_mut(
        registry.borrow_mut_id(),
        keys::vendor_clearing_house_key<VendorKey>(),
    );
    vendor_clearing_houses.push_back(ch_id);
    clearing_house
}

public(package) fun assert_package_version<T>(clearing_house: &ClearingHouse<T>) {
    assert!(clearing_house.version <= 1, EInvalidVersion)
}

fun assert_market_is_paused<T>(ch: &ClearingHouse<T>) {
    assert!(is_market_paused(ch), EMarketIsNotPaused)
}

public(package) fun assert_market_is_not_paused<T>(ch: &ClearingHouse<T>) {
    assert!(ch.paused == 0, EMarketIsPaused)
}

// Cancel-only mode (2) still lets users pull their orders.
fun assert_market_allows_order_cancellation<T>(ch: &ClearingHouse<T>) {
    assert!(ch.paused != 1, EMarketIsPaused)
}

fun assert_valid_pause_mode(pause_mode: u8) {
    assert!(pause_mode == 1 || pause_mode == 2, EInvalidPauseMode)
}

fun assert_market_is_closed<T>(ch: &ClearingHouse<T>) {
    assert!(df::exists(&ch.id, keys::settlement_prices()), EMarketIsNotClosed)
}

public(package) fun assert_market_is_not_closed<T>(ch: &ClearingHouse<T>) {
    assert!(!df::exists(&ch.id, keys::settlement_prices()), EMarketIsClosed)
}

fun assert_order_value(
    size_posted: u64,
    index_price: u256,
    min_order_usd_value: u256
) {
    assert!(
        ifixed::mul(ifixed::from_balance(size_posted, 1_000_000_000), index_price)
            >= min_order_usd_value,
        EOrderUsdValueTooLow,
    )
}

fun assert_settlement_prices(
    base_settlement_price: u256,
    collateral_settlement_price: u256,
) {
    assert!(
        ifixed::greater_than(base_settlement_price, 0)
            && ifixed::greater_than(collateral_settlement_price, 0),
        EInvalidSettlementPrices,
    )
}

// Clips a reduce-only order to the size of the position it reduces, counting what the session
// has already filled and liquidated.
fun assert_reduce_only<T>(
    hot_potato: &SessionHotPotato<T>,
    side: bool,
    size: u64,
    reduce_only: bool,
): u64 {
    if (reduce_only) {
        // Base taken over from a liquidation this session, signed like the liqee's position.
        let base_liquidated = if (hot_potato.session_summary.base_liquidated == 0) {
            0
        } else if (hot_potato.session_summary.is_liqee_long) {
            hot_potato.session_summary.base_liquidated
        } else {
            ifixed::neg(hot_potato.session_summary.base_liquidated)
        };
        let base = ifixed::add(
            ifixed::add(hot_potato.position_base_before, base_liquidated),
            ifixed::sub(
                hot_potato.session_summary.base_filled_bid,
                hot_potato.session_summary.base_filled_ask,
            ),
        );
        let is_short = ifixed::is_neg(base);
        // Asks (`side == true`) reduce longs and bids reduce shorts.
        assert!(base != 0 && is_short != side, EReduceOnlyViolated);
        let abs_base = ifixed::abs(base);
        if (ifixed::greater_than_eq(abs_base, ifixed::from_balance(size, 1_000_000_000))) {
            size
        } else {
            ifixed::to_balance(abs_base, 1_000_000_000)
        }
    } else {
        size
    }
}
