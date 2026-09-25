// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator::price_feed_storage;

use authority_cap::authority::{ADMIN, AuthorityCap};
use haneul::derived_object;
use oracle_aggregator::authority::{Self, PACKAGE, SourceCap, VENDOR};
use oracle_aggregator::config::Config;
use oracle_aggregator::events;
use oracle_aggregator::price_feed::{Self, PriceFeed};
use std::string::String;

// === Errors and constants ===

#[error(code = 0)]
const EInvalidSourceObjectForFeed: vector<u8> =
    b"The provided source object is not authorized to update this feed.";
#[error(code = 1)]
const ESourceNotAuthorized: vector<u8> =
    b"The source is not authorized to write price feeds.";

// === Types ===

public struct PriceFeedStorageKey has copy, drop, store(u32)

public struct PriceFeedStorage has key, store {
    id: UID,
    storage_id: u32,
    symbol: String,
    feeds: vector<PriceFeed>,
}

// === Functions ===

public fun new<VendorKey, ADMIN_OR_ASSISTANT>(
    config: &mut Config,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    symbol: String,
): PriceFeedStorage {
    config.assert_package_version();
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_vendor_authority_cap_is_valid(authority_cap);

    let storage_id = config.inc_storage_id();
    let mut price_feed_storage = PriceFeedStorage {
        id: derived_object::claim(config.borrow_mut_id(), PriceFeedStorageKey(storage_id)),
        storage_id,
        symbol,
        feeds: vector[],
    };
    authority::add_vendor_authorization<VendorKey>(&mut price_feed_storage.id);
    events::emit_created_price_feed_storage(price_feed_storage.id.to_inner(), storage_id, symbol);
    price_feed_storage
}

public fun derived_id(
    config: &Config,
    storage_id: u32,
): ID {
    object::id_from_address(
        derived_object::derive_address(config.id(), PriceFeedStorageKey(storage_id)),
    )
}

public fun storage_id(price_feed_storage: &PriceFeedStorage): u32 {
    price_feed_storage.storage_id
}

public fun symbol(price_feed_storage: &PriceFeedStorage): String {
    price_feed_storage.symbol
}

public fun sources(price_feed_storage: &PriceFeedStorage): vector<u16> {
    let mut sources = vector[];
    let mut i = 0;
    while (i < price_feed_storage.feeds.length()) {
        sources.push_back(price_feed_storage.feeds[i].source_id());
        i = i + 1;
    };
    sources
}

public fun feeds(price_feed_storage: &PriceFeedStorage): &vector<PriceFeed> {
    &price_feed_storage.feeds
}

public fun size(price_feed_storage: &PriceFeedStorage): u64 {
    price_feed_storage.feeds.length()
}

public fun contains(
    price_feed_storage: &PriceFeedStorage,
    source_id: u16,
): bool {
    price_feed::contains(&price_feed_storage.feeds, source_id)
}

public fun any_source(price_feed_storage: &PriceFeedStorage): bool {
    !price_feed_storage.feeds.is_empty()
}

public fun has_vendor_authorization<VendorKey>(
    price_feed_storage: &PriceFeedStorage,
): bool {
    authority::has_vendor_authorization<VendorKey>(&price_feed_storage.id)
}

public fun assert_has_vendor_authorization<VendorKey>(
    price_feed_storage: &PriceFeedStorage,
) {
    authority::assert_has_active_vendor_authority<VendorKey>(&price_feed_storage.id)
}

#[syntax(index)]
public fun price_feed(
    price_feed_storage: &PriceFeedStorage,
    source_id: u16,
): &PriceFeed {
    price_feed::borrow_feed(&price_feed_storage.feeds, source_id)
}

#[syntax(index)]
fun price_feed_mut(
    price_feed_storage: &mut PriceFeedStorage,
    source_id: u16,
): &mut PriceFeed {
    price_feed::borrow_feed_mut(&mut price_feed_storage.feeds, source_id)
}

public fun new_price_feed<VendorKey, ADMIN_OR_ASSISTANT, PriceObject: key>(
    price_feed_storage: &mut PriceFeedStorage,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_ASSISTANT>,
    config: &Config,
    source_cap: &SourceCap,
    price_object: &PriceObject,
    price: u128,
    timestamp_ms: u64,
    twap_period_ms: u64,
) {
    config.assert_package_version();
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_vendor_authority_cap_is_valid(authority_cap);
    price_feed_storage.assert_has_vendor_authorization<VendorKey>();
    assert!(source_cap.is_authorized(), ESourceNotAuthorized);

    let source_id = source_cap.source_id();
    price_feed::add_feed(
        &mut price_feed_storage.feeds,
        source_id,
        object::id(price_object),
        price,
        timestamp_ms,
        twap_period_ms,
    );
    events::emit_created_price_feed(price_feed_storage.storage_id, source_id, price, timestamp_ms)
}

public fun remove_price_feed<VendorKey>(
    price_feed_storage: &mut PriceFeedStorage,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN>,
    config: &Config,
    source_cap: &SourceCap,
) {
    config.assert_package_version();
    config.assert_vendor_authority_cap_is_valid(authority_cap);
    price_feed_storage.assert_has_vendor_authorization<VendorKey>();
    price_feed_storage.remove_price_feed_(source_cap.source_id())
}

public fun force_remove_price_feed<ADMIN_OR_ASSISTANT>(
    price_feed_storage: &mut PriceFeedStorage,
    authority_cap: &AuthorityCap<PACKAGE, ADMIN_OR_ASSISTANT>,
    config: &Config,
    source_id: u16,
) {
    config.assert_package_version();
    authority::assert_is_admin_or_assistant<ADMIN_OR_ASSISTANT>();
    config.assert_package_authority_cap_is_valid(authority_cap);
    price_feed_storage.remove_price_feed_(source_id)
}

entry fun set_symbol<VendorKey, ADMIN_OR_MAINTENANCE>(
    price_feed_storage: &mut PriceFeedStorage,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_MAINTENANCE>,
    config: &Config,
    symbol: String,
) {
    config.assert_package_version();
    authority::assert_is_admin_or_maintenance<ADMIN_OR_MAINTENANCE>();
    config.assert_vendor_authority_cap_is_valid(authority_cap);
    price_feed_storage.assert_has_vendor_authorization<VendorKey>();
    price_feed_storage.symbol = symbol
}

public fun set_twap_period_ms<VendorKey, ADMIN_OR_MAINTENANCE>(
    price_feed_storage: &mut PriceFeedStorage,
    authority_cap: &AuthorityCap<VENDOR<VendorKey>, ADMIN_OR_MAINTENANCE>,
    config: &Config,
    source_id: u16,
    twap_period_ms: u64,
) {
    config.assert_package_version();
    authority::assert_is_admin_or_maintenance<ADMIN_OR_MAINTENANCE>();
    config.assert_vendor_authority_cap_is_valid(authority_cap);
    price_feed_storage.assert_has_vendor_authorization<VendorKey>();

    let old_twap_period_ms = price_feed_storage[source_id].set_feed_twap_period_ms(twap_period_ms);
    events::emit_updated_twap_period_ms(
        price_feed_storage.storage_id,
        source_id,
        old_twap_period_ms,
        twap_period_ms,
    )
}

public fun update_price_feed<PriceObject: key>(
    price_feed_storage: &mut PriceFeedStorage,
    config: &Config,
    source_cap: &SourceCap,
    price_object: &PriceObject,
    price: u128,
    timestamp_ms: u64,
) {
    config.assert_package_version();
    assert!(source_cap.is_authorized(), ESourceNotAuthorized);

    let source_id = source_cap.source_id();
    let feed = &mut price_feed_storage[source_id];
    if (feed.from() != object::id(price_object)) {
        abort EInvalidSourceObjectForFeed
    };
    let (old_price, old_timestamp_ms, old_twap_price) = feed.price_timestamp_ms_twap_price();
    if (!feed.maybe_set_price(price, timestamp_ms)) {
        return
    };

    let new_twap_price = feed.twap_price();
    events::emit_updated_price_feed(
        price_feed_storage.storage_id,
        source_id,
        old_price,
        old_timestamp_ms,
        old_twap_price,
        price,
        timestamp_ms,
        new_twap_price,
    )
}

#[allow(lint(share_owned))]
public fun share_vec(price_feed_storages: vector<PriceFeedStorage>) {
    price_feed_storages.do!(|price_feed_storage| transfer::share_object(price_feed_storage))
}

fun remove_price_feed_(
    price_feed_storage: &mut PriceFeedStorage,
    source_id: u16,
) {
    price_feed::remove_feed(&mut price_feed_storage.feeds, source_id);
    events::emit_removed_price_feed(price_feed_storage.storage_id, source_id)
}
