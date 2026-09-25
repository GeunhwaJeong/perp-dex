// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::registry;

use authority_cap::authority as cap_authority;
use authority_cap::authority::{ADMIN, ASSISTANT, AuthorityCap};
use haneul::bag::{Self, Bag};
use haneul::dynamic_field;
use haneul::types;
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::authority::{
    Self,
    ACCOUNT,
    ADL,
    FREEZE_GUARDIAN,
    MAINTENANCE,
    PACKAGE,
    PAUSE_GUARDIAN,
    REVOKE_VENDOR_GUARDIAN,
    TREASURY,
    VENDOR,
};
use perpetuals::events;
use perpetuals::keys;
use std::type_name;
use vendor::metadata::VendorMetadata;

// === Errors and constants ===

const EInvalidVersion: u64 = 5000;
const EMarketAlreadyRegistered: u64 = 5001;
const EMarketIsNotRegistered: u64 = 5002;
const EInvalidIntegratorId: u64 = 5003;
const EIntegratorRegistrationDoesNotExist: u64 = 5004;
const EInvalidVersionUpgradeValue: u64 = 5005;
const EInvalidVendor: u64 = 5006;
const EAuthorityCapNotAuthorized: u64 = 5007;
const EInvalidFundingParameterBounds: u64 = 5008;
const EInvalidPremiumTwapBounds: u64 = 5009;
const EInvalidSpreadTwapBounds: u64 = 5010;
const EInvalidProposalDelayBounds: u64 = 5011;
const EInvalidMinOrderUsdValueBounds: u64 = 5012;
const EInvalidInsuranceOpenInterestFraction: u64 = 5013;
const EInvalidMinOracleTolerance: u64 = 5014;
const EInvalidMaxBookIndexSpread: u64 = 5015;
const EInvalidMaxIndexTwapDivergence: u64 = 5016;
const EInvalidUpMaxPendingOrders: u64 = 5017;
const EInvalidMaxAssistantsPerAccount: u64 = 5018;
const EInvalidMaxAbsMakerFee: u64 = 5019;
const EInvalidMaxAbsTakerFee: u64 = 5020;
const EInvalidMaxLiquidationFee: u64 = 5021;
const EInvalidMaxInsuranceFundFee: u64 = 5022;
const EVendorRegistrationNotApproved: u64 = 5023;
const EAuthorityCapAlreadyAuthorized: u64 = 5024;
const EVendorAdminCapDoesNotExist: u64 = 5025;
const ENotFrozen: u64 = 5026;
const EInvalidResumeVersion: u64 = 5027;
const ENotOneTimeWitness: u64 = 66;
const EExtensionNotAuthorized: u64 = 5028;

// === Types ===

public struct MarketInfo<phantom T> has store {
    base_storage_id: u32,
    base_source_id: u16,
    collateral_storage_id: u32,
    collateral_source_id: u16,
    scaling_factor: u256,
}

public struct CollateralInfo<phantom T> has store {
    collateral_storage_id: u32,
    collateral_source_id: u16,
    scaling_factor: u256,
}

public struct IntegratorRegistration has store { integrator_address: address }

public struct Config has store {
    stop_order_geunhwa_cost: u64,
    max_abs_maker_fee: u256,
    max_abs_taker_fee: u256,
    max_liquidation_fee: u256,
    max_insurance_fund_fee: u256,
    min_funding_frequency_ms: u64,
    min_funding_period_ms: u64,
    max_funding_period_ms: u64,
    min_premium_twap_frequency_ms: u64,
    min_premium_twap_period_ms: u64,
    min_spread_twap_frequency_ms: u64,
    min_spread_twap_period_ms: u64,
    min_proposal_delay_ms: u64,
    max_proposal_delay_ms: u64,
    low_min_order_usd_value: u256,
    up_min_order_usd_value: u256,
    insurance_open_interest_fraction: u256,
    min_oracle_tolerance: u64,
    max_book_index_spread: u256,
    max_index_twap_divergence: u256,
    up_max_pending_orders: u64,
    max_assistants_per_account: u64,
    extra_fields: Bag,
}

public struct Registry has key {
    id: UID,
    version: u64,
    next_account_id: u64,
    next_integrator_id: u32,
}

// === Functions ===

public fun max_abs_maker_fee(config: &Config): u256 {
    config.max_abs_maker_fee
}

public fun max_abs_taker_fee(config: &Config): u256 {
    config.max_abs_taker_fee
}

public fun max_liquidation_fee(config: &Config): u256 {
    config.max_liquidation_fee
}

public fun max_insurance_fund_fee(config: &Config): u256 {
    config.max_insurance_fund_fee
}

public fun min_funding_frequency_ms(config: &Config): u64 {
    config.min_funding_frequency_ms
}

public fun min_funding_period_ms(config: &Config): u64 {
    config.min_funding_period_ms
}

public fun max_funding_period_ms(config: &Config): u64 {
    config.max_funding_period_ms
}

public fun min_premium_twap_frequency_ms(config: &Config): u64 {
    config.min_premium_twap_frequency_ms
}

public fun min_premium_twap_period_ms(config: &Config): u64 {
    config.min_premium_twap_period_ms
}

public fun min_spread_twap_frequency_ms(config: &Config): u64 {
    config.min_spread_twap_frequency_ms
}

public fun min_spread_twap_period_ms(config: &Config): u64 {
    config.min_spread_twap_period_ms
}

public fun min_proposal_delay_ms(config: &Config): u64 {
    config.min_proposal_delay_ms
}

public fun max_proposal_delay_ms(config: &Config): u64 {
    config.max_proposal_delay_ms
}

public fun low_min_order_usd_value(config: &Config): u256 {
    config.low_min_order_usd_value
}

public fun up_min_order_usd_value(config: &Config): u256 {
    config.up_min_order_usd_value
}

public fun insurance_open_interest_fraction(config: &Config): u256 {
    config.insurance_open_interest_fraction
}

public fun min_oracle_tolerance(config: &Config): u64 {
    config.min_oracle_tolerance
}

public fun max_book_index_spread(config: &Config): u256 {
    config.max_book_index_spread
}

public fun max_index_twap_divergence(config: &Config): u256 {
    config.max_index_twap_divergence
}

public fun up_max_pending_orders(config: &Config): u64 {
    config.up_max_pending_orders
}

public fun max_assistants_per_account(config: &Config): u64 {
    config.max_assistants_per_account
}

public(package) fun create_registry<T: drop>(witness: &T, ctx: &mut TxContext): Registry {
    assert!(types::is_one_time_witness(witness), ENotOneTimeWitness);
    let mut registry = Registry {
        id: object::new(ctx),
        version: 1,
        next_account_id: 0,
        next_integrator_id: 0,
    };
    let config = Config {
        stop_order_geunhwa_cost: 1_000_000,
        max_abs_maker_fee: ifixed::from_u64fraction(500, 10000),
        max_abs_taker_fee: ifixed::from_u64fraction(500, 10000),
        max_liquidation_fee: ifixed::from_u64fraction(500, 10000),
        max_insurance_fund_fee: ifixed::from_u64fraction(500, 10000),
        min_funding_frequency_ms: 60_000, // 1 minute
        min_funding_period_ms: 21_600_000, // 6 hours
        max_funding_period_ms: 864_000_000, // 10 days
        min_premium_twap_frequency_ms: 1_000,
        min_premium_twap_period_ms: 60_000,
        min_spread_twap_frequency_ms: 1_000,
        min_spread_twap_period_ms: 60_000,
        min_proposal_delay_ms: 86_400_000, // 1 day
        max_proposal_delay_ms: 259_200_000, // 3 days
        low_min_order_usd_value: ifixed::from_u64fraction(50, 100),
        up_min_order_usd_value: ifixed::from_u64fraction(100000, 100),
        insurance_open_interest_fraction: ifixed::from_u64fraction(500, 10000),
        min_oracle_tolerance: 500,
        max_book_index_spread: ifixed::from_u64fraction(20, 100),
        max_index_twap_divergence: ifixed::from_u64fraction(2000, 10000),
        up_max_pending_orders: 100,
        max_assistants_per_account: 10,
        extra_fields: bag::new(ctx),
    };
    dynamic_field::add(&mut registry.id, keys::registry_config(), config);
    registry
}

public fun share(registry: Registry) {
    transfer::share_object(registry)
}

public(package) fun borrow_mut_id(
    registry: &mut Registry,
): &mut UID {
    &mut registry.id
}

public fun version(registry: &Registry): u64 {
    registry.version
}

public(package) fun config(registry: &Registry): &Config {
    dynamic_field::borrow(&registry.id, keys::registry_config())
}

fun config_mut(registry: &mut Registry): &mut Config {
    dynamic_field::borrow_mut(&mut registry.id, keys::registry_config())
}

public fun is_market_registered(
    registry: &Registry,
    ch_id: ID
): bool {
    dynamic_field::exists(&registry.id, keys::registry_market_info(ch_id))
}

public fun is_collateral_registered<T>(
    registry: &Registry,
): bool {
    dynamic_field::exists(&registry.id, keys::registry_collateral_info<T>())
}

public fun is_integrator_id_registered(
    registry: &Registry,
    integrator_id: u32
): bool {
    integrator_id < registry.next_integrator_id
}

public fun is_frozen(registry: &Registry): bool {
    dynamic_field::exists_with_type<_, u64>(&registry.id, keys::frozen_version())
}

public fun is_vendor_registration_open(registry: &Registry): bool {
    let key = keys::vendor_registration_open();
    dynamic_field::exists_with_type<_, bool>(&registry.id, key)
        && *dynamic_field::borrow<_, bool>(&registry.id, key)
}

public fun is_authority_cap_authorized<Context, Role>(
    registry: &Registry,
    cap_id: ID,
): bool {
    cap_authority::is_cap_authorized<Context, Role>(&registry.id, cap_id)
}

public fun is_account_assistant_cap_registered(
    registry: &Registry,
    account_cap_id: ID,
): bool {
    cap_authority::is_cap_authorized<ACCOUNT, ASSISTANT>(&registry.id, account_cap_id)
}

public fun market_info<T>(registry: &Registry, ch_id: ID): (u32, u16, u32, u16, u256) {
    let info: &MarketInfo<T> = dynamic_field::borrow(
        &registry.id,
        keys::registry_market_info(ch_id),
    );
    (
        info.base_storage_id,
        info.base_source_id,
        info.collateral_storage_id,
        info.collateral_source_id,
        info.scaling_factor,
    )
}

public fun collateral_info<T>(registry: &Registry): (u32, u16, u256) {
    let info: &CollateralInfo<T> = dynamic_field::borrow(
        &registry.id,
        keys::registry_collateral_info<T>(),
    );
    (info.collateral_storage_id, info.collateral_source_id, info.scaling_factor)
}

public fun stop_order_geunhwa_cost(registry: &Registry): u64 {
    registry.config().stop_order_geunhwa_cost
}

fun option_u64_or(value: &Option<u64>, fallback: u64): u64 {
    if (value.is_some()) *value.borrow() else fallback
}

fun option_u256_or(value: &Option<u256>, fallback: u256): u256 {
    if (value.is_some()) *value.borrow() else fallback
}

public fun integrator_address(registry: &Registry, integrator_id: u32): address {
    dynamic_field::borrow<_, IntegratorRegistration>(
        &registry.id,
        keys::integrator_registration(integrator_id),
    ).integrator_address
}

public fun register_integrator(
    registry: &mut Registry,
    ctx: &mut TxContext,
): u32 {
    registry.assert_package_version();
    let integrator_address = ctx.sender();
    let integrator_id = registry.inc_integrator_id();
    dynamic_field::add(
        &mut registry.id,
        keys::integrator_registration(integrator_id),
        IntegratorRegistration { integrator_address },
    );
    integrator_id
}

public(package) fun register_market<T>(
    registry: &mut Registry,
    base_storage_id: u32,
    base_source_id: u16,
    collateral_storage_id: u32,
    collateral_source_id: u16,
    scaling_factor: u256,
    ch_id: ID,
) {
    registry.assert_package_version();
    assert!(!registry.is_market_registered(ch_id), EMarketAlreadyRegistered);
    dynamic_field::add(
        &mut registry.id,
        keys::registry_market_info(ch_id),
        MarketInfo<T> {
            base_storage_id,
            base_source_id,
            collateral_storage_id,
            collateral_source_id,
            scaling_factor,
        },
    );
    // The first market of a collateral type also registers that collateral.
    if (!registry.is_collateral_registered<T>()) {
        dynamic_field::add(
            &mut registry.id,
            keys::registry_collateral_info<T>(),
            CollateralInfo<T> { collateral_storage_id, collateral_source_id, scaling_factor },
        );
        events::registered_collateral_info<T>(collateral_storage_id, collateral_source_id, scaling_factor)
    }
}

public(package) fun remove_registered_market<T>(registry: &mut Registry, ch_id: ID) {
    registry.assert_package_version();
    assert!(registry.is_market_registered(ch_id), EMarketIsNotRegistered);
    let MarketInfo<T> {
        base_storage_id: _,
        base_source_id: _,
        collateral_storage_id: _,
        collateral_source_id: _,
        scaling_factor: _,
    } = dynamic_field::remove(&mut registry.id, keys::registry_market_info(ch_id));
}

public(package) fun set_base_oracle_params_<T>(
    registry: &mut Registry,
    ch_id: ID,
    storage_id: u32,
    source_id: u16,
) {
    registry.assert_package_version();
    let info: &mut MarketInfo<T> = dynamic_field::borrow_mut(
        &mut registry.id,
        keys::registry_market_info(ch_id),
    );
    info.base_storage_id = storage_id;
    info.base_source_id = source_id
}

public(package) fun set_collateral_oracle_params_<T>(
    registry: &mut Registry,
    ch_id: ID,
    storage_id: u32,
    source_id: u16,
) {
    registry.assert_package_version();
    let info: &mut MarketInfo<T> = dynamic_field::borrow_mut(
        &mut registry.id,
        keys::registry_market_info(ch_id),
    );
    info.collateral_storage_id = storage_id;
    info.collateral_source_id = source_id
}

public fun set_integrator_address(
    registry: &mut Registry,
    integrator_id: u32,
    new_integrator_address: address,
    ctx: &TxContext,
) {
    registry.assert_package_version();
    assert!(registry.is_integrator_id_registered(integrator_id), EInvalidIntegratorId);
    let current_address = dynamic_field::borrow<_, IntegratorRegistration>(
        &registry.id,
        keys::integrator_registration(integrator_id),
    ).integrator_address;
    assert!(current_address == ctx.sender(), EInvalidIntegratorId);
    registry.set_integrator_address_(integrator_id, new_integrator_address)
}

public fun deauthorize_authority_cap<Context, Role>(
    registry: &mut Registry,
    cap: &AuthorityCap<Context, ADMIN>,
    cap_id: ID,
) {
    registry.assert_package_version();
    authority::assert_is_not_admin<Role>();
    registry.assert_admin_authority_cap_is_active(cap);
    registry.deauthorize_authority_cap_<Context, Role>(cap_id)
}

public fun create_package_assistant_cap(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ASSISTANT> {
    registry.assert_package_version();
    let cap = authority::create_package_assistant_cap(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun create_package_adl_cap(
    registry: &mut Registry,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, ADL> {
    registry.assert_package_version();
    let cap = authority::create_package_adl_cap(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun create_package_pause_guardian_cap(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, PAUSE_GUARDIAN> {
    registry.assert_package_version();
    let cap = authority::create_package_pause_guardian_cap(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

entry fun set_vendor_registration(
    registry: &mut Registry,
    _: &AuthorityCap<PACKAGE, ADMIN>,
    open: bool,
) {
    registry.assert_package_version();
    let key = keys::vendor_registration_open();
    if (dynamic_field::exists(&registry.id, key)) {
        *dynamic_field::borrow_mut(&mut registry.id, key) = open
    } else {
        dynamic_field::add(&mut registry.id, key, open)
    }
}

public fun create_package_revoke_vendor_guardian_cap(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN> {
    registry.assert_package_version();
    let cap = authority::create_package_revoke_vendor_guardian_cap(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun reauthorize_vendor_admin_cap<VendorKey>(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
) {
    registry.assert_package_version();
    assert!(
        cap_authority::exists<VENDOR<VendorKey>, ADMIN>(&registry.id),
        EVendorAdminCapDoesNotExist,
    );
    let cap_id = cap_authority::derived_cap_id<VENDOR<VendorKey>, ADMIN>(&registry.id);
    assert!(
        !registry.is_authority_cap_authorized<VENDOR<VendorKey>, ADMIN>(cap_id),
        EAuthorityCapAlreadyAuthorized,
    );
    dynamic_field::add(
        &mut registry.id,
        cap_authority::authorized_authority_cap_key<VENDOR<VendorKey>, ADMIN>(cap_id),
        true,
    )
}

public fun create_package_freeze_guardian_cap(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<PACKAGE, FREEZE_GUARDIAN> {
    registry.assert_package_version();
    let cap = authority::create_package_freeze_guardian_cap(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun unfreeze_package(
    registry: &mut Registry,
    _cap: &AuthorityCap<PACKAGE, ADMIN>,
) {
    assert!(registry.is_frozen(), ENotFrozen);
    let resume_version = dynamic_field::remove<_, u64>(&mut registry.id, keys::frozen_version());
    assert!(resume_version <= 1, EInvalidResumeVersion);
    registry.version = resume_version;
    events::unfroze(registry.id.to_inner(), resume_version)
}

public fun freeze_package(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, FREEZE_GUARDIAN>,
) {
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    let resume_version = registry.version;
    dynamic_field::add(&mut registry.id, keys::frozen_version(), resume_version);
    // No package version can satisfy `assert_package_version` until the registry is unfrozen.
    registry.version = std::u64::max_value!();
    events::froze(registry.id.to_inner(), resume_version, object::id(cap))
}

public fun guardian_deauthorize_authority_cap<VendorKey, Role>(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, REVOKE_VENDOR_GUARDIAN>,
    cap_id: ID,
) {
    registry.assert_package_version();
    registry.assert_authority_cap_is_authorized(cap);
    registry.deauthorize_authority_cap_<VENDOR<VendorKey>, Role>(cap_id)
}

entry fun upgrade_version<ADMIN_OR_ASSISTANT>(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
) {
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    assert!(registry.version < 1, EInvalidVersionUpgradeValue);
    events::upgraded_version(registry.id.to_inner(), 1);
    registry.version = 1
}

public fun set_integrator_address_with_cap<ADMIN_OR_ASSISTANT>(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    integrator_id: u32,
    new_integrator_address: address,
) {
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    assert!(registry.is_integrator_id_registered(integrator_id), EInvalidIntegratorId);
    registry.set_integrator_address_(integrator_id, new_integrator_address)
}

public fun set_collateral_info<T, ADMIN_OR_ASSISTANT>(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    pfs: &PriceFeedStorage,
    source_id: u16,
) {
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);
    let info: &mut CollateralInfo<T> = dynamic_field::borrow_mut(
        &mut registry.id,
        keys::registry_collateral_info<T>(),
    );
    info.collateral_storage_id = pfs.storage_id();
    info.collateral_source_id = source_id;
    events::registered_collateral_info<T>(info.collateral_storage_id, info.collateral_source_id, info.scaling_factor)
}

/// A set of registry bounds to change; unset fields keep their current value. Built with
/// `new_config_update` and the `set_*` setters, applied with `apply_config_update`.
public struct ConfigUpdate has copy, drop {
    stop_order_geunhwa_cost: Option<u64>,
    max_abs_maker_fee: Option<u256>,
    max_abs_taker_fee: Option<u256>,
    max_liquidation_fee: Option<u256>,
    max_insurance_fund_fee: Option<u256>,
    min_funding_frequency_ms: Option<u64>,
    min_funding_period_ms: Option<u64>,
    max_funding_period_ms: Option<u64>,
    min_premium_twap_frequency_ms: Option<u64>,
    min_premium_twap_period_ms: Option<u64>,
    min_spread_twap_frequency_ms: Option<u64>,
    min_spread_twap_period_ms: Option<u64>,
    min_proposal_delay_ms: Option<u64>,
    max_proposal_delay_ms: Option<u64>,
    low_min_order_usd_value: Option<u256>,
    up_min_order_usd_value: Option<u256>,
    insurance_open_interest_fraction: Option<u256>,
    min_oracle_tolerance: Option<u64>,
    max_book_index_spread: Option<u256>,
    max_index_twap_divergence: Option<u256>,
    up_max_pending_orders: Option<u64>,
    max_assistants_per_account: Option<u64>,
}

public fun new_config_update(): ConfigUpdate {
    ConfigUpdate {
        stop_order_geunhwa_cost: option::none(),
        max_abs_maker_fee: option::none(),
        max_abs_taker_fee: option::none(),
        max_liquidation_fee: option::none(),
        max_insurance_fund_fee: option::none(),
        min_funding_frequency_ms: option::none(),
        min_funding_period_ms: option::none(),
        max_funding_period_ms: option::none(),
        min_premium_twap_frequency_ms: option::none(),
        min_premium_twap_period_ms: option::none(),
        min_spread_twap_frequency_ms: option::none(),
        min_spread_twap_period_ms: option::none(),
        min_proposal_delay_ms: option::none(),
        max_proposal_delay_ms: option::none(),
        low_min_order_usd_value: option::none(),
        up_min_order_usd_value: option::none(),
        insurance_open_interest_fraction: option::none(),
        min_oracle_tolerance: option::none(),
        max_book_index_spread: option::none(),
        max_index_twap_divergence: option::none(),
        up_max_pending_orders: option::none(),
        max_assistants_per_account: option::none(),
    }
}

public fun set_fee_caps(
    update: &mut ConfigUpdate,
    max_abs_maker_fee: u256,
    max_abs_taker_fee: u256,
    max_liquidation_fee: u256,
    max_insurance_fund_fee: u256,
) {
    update.max_abs_maker_fee = option::some(max_abs_maker_fee);
    update.max_abs_taker_fee = option::some(max_abs_taker_fee);
    update.max_liquidation_fee = option::some(max_liquidation_fee);
    update.max_insurance_fund_fee = option::some(max_insurance_fund_fee);
}

/// Funding frequency floor, funding period bounds, and the premium and spread TWAP floors.
public fun set_timing_bounds(
    update: &mut ConfigUpdate,
    min_funding_frequency_ms: u64,
    min_funding_period_ms: u64,
    max_funding_period_ms: u64,
    min_premium_twap_frequency_ms: u64,
    min_premium_twap_period_ms: u64,
    min_spread_twap_frequency_ms: u64,
    min_spread_twap_period_ms: u64,
) {
    update.min_funding_frequency_ms = option::some(min_funding_frequency_ms);
    update.min_funding_period_ms = option::some(min_funding_period_ms);
    update.max_funding_period_ms = option::some(max_funding_period_ms);
    update.min_premium_twap_frequency_ms = option::some(min_premium_twap_frequency_ms);
    update.min_premium_twap_period_ms = option::some(min_premium_twap_period_ms);
    update.min_spread_twap_frequency_ms = option::some(min_spread_twap_frequency_ms);
    update.min_spread_twap_period_ms = option::some(min_spread_twap_period_ms);
}

/// Margin ratio proposal delay bounds and the range a market's minimum order value may take.
public fun set_proposal_and_order_value_bounds(
    update: &mut ConfigUpdate,
    min_proposal_delay_ms: u64,
    max_proposal_delay_ms: u64,
    low_min_order_usd_value: u256,
    up_min_order_usd_value: u256,
) {
    update.min_proposal_delay_ms = option::some(min_proposal_delay_ms);
    update.max_proposal_delay_ms = option::some(max_proposal_delay_ms);
    update.low_min_order_usd_value = option::some(low_min_order_usd_value);
    update.up_min_order_usd_value = option::some(up_min_order_usd_value);
}

/// Insurance reserve fraction, oracle tolerance floor, and the caps on the book-index spread
/// and index-TWAP divergence a market may allow.
public fun set_risk_caps(
    update: &mut ConfigUpdate,
    insurance_open_interest_fraction: u256,
    min_oracle_tolerance: u64,
    max_book_index_spread: u256,
    max_index_twap_divergence: u256,
) {
    update.insurance_open_interest_fraction = option::some(insurance_open_interest_fraction);
    update.min_oracle_tolerance = option::some(min_oracle_tolerance);
    update.max_book_index_spread = option::some(max_book_index_spread);
    update.max_index_twap_divergence = option::some(max_index_twap_divergence);
}

/// Stop order gas floor, the pending order cap a market may set, and assistants per account.
public fun set_account_limits(
    update: &mut ConfigUpdate,
    stop_order_geunhwa_cost: u64,
    up_max_pending_orders: u64,
    max_assistants_per_account: u64,
) {
    update.stop_order_geunhwa_cost = option::some(stop_order_geunhwa_cost);
    update.up_max_pending_orders = option::some(up_max_pending_orders);
    update.max_assistants_per_account = option::some(max_assistants_per_account);
}

/// Applies `update` to the registry's bounds after validating the resulting configuration.
public fun apply_config_update<ADMIN_OR_ASSISTANT>(
    registry: &mut Registry,
    cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    update: ConfigUpdate,
) {
    registry.assert_package_version();
    registry.assert_admin_or_authorized_assistant_authority_cap(cap);

    // Unset options keep their current value.
    let current = registry.config();
    let stop_order_geunhwa_cost = option_u64_or(&update.stop_order_geunhwa_cost, current.stop_order_geunhwa_cost);
    let max_abs_maker_fee = option_u256_or(&update.max_abs_maker_fee, current.max_abs_maker_fee);
    let max_abs_taker_fee = option_u256_or(&update.max_abs_taker_fee, current.max_abs_taker_fee);
    let max_liquidation_fee = option_u256_or(&update.max_liquidation_fee, current.max_liquidation_fee);
    let max_insurance_fund_fee = option_u256_or(&update.max_insurance_fund_fee, current.max_insurance_fund_fee);
    let min_funding_frequency_ms = option_u64_or(&update.min_funding_frequency_ms, current.min_funding_frequency_ms);
    let min_funding_period_ms = option_u64_or(&update.min_funding_period_ms, current.min_funding_period_ms);
    let max_funding_period_ms = option_u64_or(&update.max_funding_period_ms, current.max_funding_period_ms);
    let min_premium_twap_frequency_ms = option_u64_or(&update.min_premium_twap_frequency_ms, current.min_premium_twap_frequency_ms);
    let min_premium_twap_period_ms = option_u64_or(&update.min_premium_twap_period_ms, current.min_premium_twap_period_ms);
    let min_spread_twap_frequency_ms = option_u64_or(&update.min_spread_twap_frequency_ms, current.min_spread_twap_frequency_ms);
    let min_spread_twap_period_ms = option_u64_or(&update.min_spread_twap_period_ms, current.min_spread_twap_period_ms);
    let min_proposal_delay_ms = option_u64_or(&update.min_proposal_delay_ms, current.min_proposal_delay_ms);
    let max_proposal_delay_ms = option_u64_or(&update.max_proposal_delay_ms, current.max_proposal_delay_ms);
    let low_min_order_usd_value = option_u256_or(&update.low_min_order_usd_value, current.low_min_order_usd_value);
    let up_min_order_usd_value = option_u256_or(&update.up_min_order_usd_value, current.up_min_order_usd_value);
    let insurance_open_interest_fraction = option_u256_or(&update.insurance_open_interest_fraction, current.insurance_open_interest_fraction);
    let min_oracle_tolerance = option_u64_or(&update.min_oracle_tolerance, current.min_oracle_tolerance);
    let max_book_index_spread = option_u256_or(&update.max_book_index_spread, current.max_book_index_spread);
    let max_index_twap_divergence = option_u256_or(&update.max_index_twap_divergence, current.max_index_twap_divergence);
    let up_max_pending_orders = option_u64_or(&update.up_max_pending_orders, current.up_max_pending_orders);
    let max_assistants_per_account = option_u64_or(&update.max_assistants_per_account, current.max_assistants_per_account);

    // Fee caps and fractions are IFixed values in [0, 1] (1.0 = 1e18).
    assert!(
        ifixed::greater_than_eq(max_abs_maker_fee, 0)
            && ifixed::less_than_eq(max_abs_maker_fee, 1_000_000_000_000_000_000),
        EInvalidMaxAbsMakerFee,
    );
    assert!(
        ifixed::greater_than_eq(max_abs_taker_fee, 0)
            && ifixed::less_than_eq(max_abs_taker_fee, 1_000_000_000_000_000_000),
        EInvalidMaxAbsTakerFee,
    );
    assert!(
        ifixed::greater_than_eq(max_liquidation_fee, 0)
            && ifixed::less_than_eq(max_liquidation_fee, 1_000_000_000_000_000_000),
        EInvalidMaxLiquidationFee,
    );
    assert!(
        ifixed::greater_than_eq(max_insurance_fund_fee, 0)
            && ifixed::less_than_eq(max_insurance_fund_fee, 1_000_000_000_000_000_000),
        EInvalidMaxInsuranceFundFee,
    );
    assert!(
        min_funding_frequency_ms > 0
            && min_funding_frequency_ms < min_funding_period_ms
            && min_funding_period_ms < max_funding_period_ms,
        EInvalidFundingParameterBounds,
    );
    assert!(
        min_premium_twap_frequency_ms > 0
            && min_premium_twap_period_ms >= min_premium_twap_frequency_ms,
        EInvalidPremiumTwapBounds,
    );
    assert!(
        min_spread_twap_frequency_ms > 0
            && min_spread_twap_period_ms >= min_spread_twap_frequency_ms,
        EInvalidSpreadTwapBounds,
    );
    assert!(
        min_proposal_delay_ms > 0 && min_proposal_delay_ms <= max_proposal_delay_ms,
        EInvalidProposalDelayBounds,
    );
    assert!(
        ifixed::greater_than_eq(low_min_order_usd_value, 0)
            && ifixed::less_than_eq(low_min_order_usd_value, up_min_order_usd_value),
        EInvalidMinOrderUsdValueBounds,
    );
    assert!(
        ifixed::greater_than_eq(insurance_open_interest_fraction, 0)
            && ifixed::less_than_eq(insurance_open_interest_fraction, 1_000_000_000_000_000_000),
        EInvalidInsuranceOpenInterestFraction,
    );
    assert!(min_oracle_tolerance > 0, EInvalidMinOracleTolerance);
    assert!(
        ifixed::greater_than_eq(max_book_index_spread, 0)
            && ifixed::less_than_eq(max_book_index_spread, 1_000_000_000_000_000_000),
        EInvalidMaxBookIndexSpread,
    );
    assert!(
        ifixed::greater_than_eq(max_index_twap_divergence, 0)
            && ifixed::less_than_eq(max_index_twap_divergence, 1_000_000_000_000_000_000),
        EInvalidMaxIndexTwapDivergence,
    );
    assert!(up_max_pending_orders > 0, EInvalidUpMaxPendingOrders);
    assert!(max_assistants_per_account > 0, EInvalidMaxAssistantsPerAccount);

    let config = registry.config_mut();
    config.stop_order_geunhwa_cost = stop_order_geunhwa_cost;
    config.max_abs_maker_fee = max_abs_maker_fee;
    config.max_abs_taker_fee = max_abs_taker_fee;
    config.max_liquidation_fee = max_liquidation_fee;
    config.max_insurance_fund_fee = max_insurance_fund_fee;
    config.min_funding_frequency_ms = min_funding_frequency_ms;
    config.min_funding_period_ms = min_funding_period_ms;
    config.max_funding_period_ms = max_funding_period_ms;
    config.min_premium_twap_frequency_ms = min_premium_twap_frequency_ms;
    config.min_premium_twap_period_ms = min_premium_twap_period_ms;
    config.min_spread_twap_frequency_ms = min_spread_twap_frequency_ms;
    config.min_spread_twap_period_ms = min_spread_twap_period_ms;
    config.min_proposal_delay_ms = min_proposal_delay_ms;
    config.max_proposal_delay_ms = max_proposal_delay_ms;
    config.low_min_order_usd_value = low_min_order_usd_value;
    config.up_min_order_usd_value = up_min_order_usd_value;
    config.insurance_open_interest_fraction = insurance_open_interest_fraction;
    config.min_oracle_tolerance = min_oracle_tolerance;
    config.max_book_index_spread = max_book_index_spread;
    config.max_index_twap_divergence = max_index_twap_divergence;
    config.up_max_pending_orders = up_max_pending_orders;
    config.max_assistants_per_account = max_assistants_per_account
}

/// Extensions are packages that drive sessions, collateral and order tickets on behalf of
/// accounts through the `*_as_extension` entry points of `clearing_house` and `account`,
/// presenting a witness of type `W` that only they can create. The package admin authorizes
/// each witness type once.
public fun authorize_extension<W>(registry: &mut Registry, _: &AuthorityCap<PACKAGE, ADMIN>) {
    registry.assert_package_version();
    dynamic_field::add(&mut registry.id, keys::authorized_extension<W>(), true)
}

public fun deauthorize_extension<W>(registry: &mut Registry, _: &AuthorityCap<PACKAGE, ADMIN>) {
    registry.assert_package_version();
    let _: bool = dynamic_field::remove(&mut registry.id, keys::authorized_extension<W>());
}

public fun is_extension_authorized<W>(registry: &Registry): bool {
    dynamic_field::exists(&registry.id, keys::authorized_extension<W>())
}

public fun assert_extension_authorized<W>(registry: &Registry) {
    assert!(registry.is_extension_authorized<W>(), EExtensionNotAuthorized)
}

public fun register_vendor<VendorKey, ADMIN_OR_ASSISTANT>(
    registry: &mut Registry,
    cap: &AuthorityCap<vendor::authority::VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    vendor_config: &vendor::config::Config,
    metadata: &mut VendorMetadata<VendorKey>,
): AuthorityCap<VENDOR<VendorKey>, ADMIN> {
    registry.assert_package_version();
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    vendor_config.assert_has_active_vendor_authority(cap);
    assert!(
        registry.is_vendor_registration_open()
            || metadata.is_domain_registration_approved<VendorKey, PACKAGE>(),
        EVendorRegistrationNotApproved,
    );

    dynamic_field::add(
        &mut registry.id,
        keys::vendor_clearing_house_key<VendorKey>(),
        vector<ID>[],
    );
    let admin_cap = authority::create_vendor_admin_cap<VendorKey>(&mut registry.id);
    registry.authorize_authority_cap(&admin_cap);
    events::registered_vendor(type_name::with_defining_ids<VendorKey>(), object::id(&admin_cap));
    admin_cap
}

public fun create_vendor_assistant_cap<VendorKey>(
    registry: &mut Registry,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, ASSISTANT> {
    registry.assert_package_version();
    registry.assert_admin_authority_cap_is_active(admin_cap);
    let cap = authority::create_vendor_assistant_cap<VendorKey>(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun create_vendor_pause_guardian_cap<VendorKey>(
    registry: &mut Registry,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, PAUSE_GUARDIAN> {
    registry.assert_package_version();
    registry.assert_admin_authority_cap_is_active(admin_cap);
    let cap = authority::create_vendor_pause_guardian_cap<VendorKey>(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun create_vendor_maintenance_cap<VendorKey>(
    registry: &mut Registry,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext,
): AuthorityCap<VENDOR<VendorKey>, MAINTENANCE> {
    registry.assert_package_version();
    registry.assert_admin_authority_cap_is_active(admin_cap);
    let cap = authority::create_vendor_maintenance_cap<VendorKey>(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public fun create_vendor_treasury_cap<VendorKey>(
    registry: &mut Registry,
    admin_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    ctx: &mut TxContext
): AuthorityCap<VENDOR<VendorKey>, TREASURY> {
    registry.assert_package_version();
    registry.assert_admin_authority_cap_is_active(admin_cap);
    let cap = authority::create_vendor_treasury_cap<VendorKey>(&mut registry.id, ctx);
    registry.authorize_authority_cap(&cap);
    cap
}

public(package) fun authorize_authority_cap<Context, Role>(
    registry: &mut Registry,
    cap: &AuthorityCap<Context, Role>,
) {
    cap_authority::authorize_cap(&mut registry.id, cap)
}

public(package) fun register_account_assistant_cap(
    registry: &mut Registry,
    cap: &AuthorityCap<ACCOUNT, ASSISTANT>,
) {
    cap_authority::authorize_cap(&mut registry.id, cap)
}

public(package) fun unregister_account_assistant_cap_if_registered(
    registry: &mut Registry,
    account_cap_id: ID,
) {
    if (!registry.is_account_assistant_cap_registered(account_cap_id)) {
        return
    };
    cap_authority::deauthorize_cap<ACCOUNT, ASSISTANT>(&mut registry.id, account_cap_id)
}

public(package) fun deauthorize_authority_cap_<Context, Role>(registry: &mut Registry, cap_id: ID) {
    registry.assert_authority_cap_id_is_authorized<Context, Role>(cap_id);
    cap_authority::deauthorize_cap<Context, Role>(&mut registry.id, cap_id)
}

public(package) fun inc_account_id(registry: &mut Registry): u64 {
    let account_id = registry.next_account_id;
    registry.next_account_id = account_id + 1;
    account_id
}

fun inc_integrator_id(registry: &mut Registry): u32 {
    let integrator_id = registry.next_integrator_id;
    registry.next_integrator_id = integrator_id + 1;
    integrator_id
}

fun set_integrator_address_(
    registry: &mut Registry,
    integrator_id: u32,
    new_integrator_address: address,
) {
    let registration: &mut IntegratorRegistration = dynamic_field::borrow_mut(
        &mut registry.id,
        keys::integrator_registration(integrator_id),
    );
    let previous_integrator_address = registration.integrator_address;
    registration.integrator_address = new_integrator_address;
    events::updated_integrator_address(integrator_id, previous_integrator_address, new_integrator_address)
}

public fun assert_package_version(registry: &Registry) {
    assert!(registry.version <= 1, EInvalidVersion)
}

public(package) fun assert_authority_cap_is_authorized<Context, Role>(
    registry: &Registry,
    cap: &AuthorityCap<Context, Role>,
) {
    registry.assert_authority_cap_id_is_authorized<Context, Role>(object::id(cap))
}

/// The package admin cap is minted once at init and cannot be revoked, so only other contexts'
/// (vendor) admin caps are checked against the registry.
public(package) fun assert_admin_authority_cap_is_active<Context, Role>(
    registry: &Registry,
    cap: &AuthorityCap<Context, Role>,
) {
    if (type_name::with_defining_ids<Context>() != type_name::with_defining_ids<PACKAGE>()) {
        registry.assert_authority_cap_is_authorized(cap)
    }
}

public(package) fun assert_admin_or_authorized_assistant_authority_cap<Context, Role>(
    registry: &Registry,
    cap: &AuthorityCap<Context, Role>,
) {
    authority::assert_is_admin_or_assistant<Role>();
    let role = type_name::with_defining_ids<Role>();
    let assistant = type_name::with_defining_ids<ASSISTANT>();
    if (role == assistant) {
        registry.assert_authority_cap_is_authorized(cap)
    } else {
        registry.assert_admin_authority_cap_is_active(cap)
    }
}

public(package) fun assert_admin_or_authorized_assistant_or_maintenance_authority_cap<Context, Role>(
    registry: &Registry,
    cap: &AuthorityCap<Context, Role>,
) {
    authority::assert_is_admin_or_assistant_or_maintenance<Role>();
    let role = type_name::with_defining_ids<Role>();
    let is_assistant_or_maintenance = role == type_name::with_defining_ids<ASSISTANT>()
        || role == type_name::with_defining_ids<MAINTENANCE>();
    if (is_assistant_or_maintenance) {
        registry.assert_authority_cap_is_authorized(cap)
    } else {
        registry.assert_admin_authority_cap_is_active(cap)
    }
}

fun assert_authority_cap_id_is_authorized<Context, Role>(
    registry: &Registry,
    cap_id: ID,
) {
    assert!(
        registry.is_authority_cap_authorized<Context, Role>(cap_id),
        EAuthorityCapNotAuthorized,
    )
}

public(package) fun assert_vendor_has_ownership_over_clearing_house<VendorKey, Role>(
    registry: &Registry,
    _: &AuthorityCap<VENDOR<VendorKey>, Role>,
    clearing_house_id: &ID,
) {
    let clearing_house_ids: &vector<ID> = dynamic_field::borrow(
        &registry.id,
        keys::vendor_clearing_house_key<VendorKey>(),
    );
    let idx = clearing_house_ids.find_index!(|e| e == clearing_house_id);
    assert!(idx.is_some(), EInvalidVendor)
}

public(package) fun assert_integrator_id_is_valid(
    registry: &Registry,
    integrator_id: u32,
) {
    assert!(
        registry.is_integrator_id_registered(integrator_id),
        EIntegratorRegistrationDoesNotExist,
    )
}
