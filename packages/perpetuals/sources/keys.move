// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module perpetuals::keys;

// === Types ===

public struct RegistryMarketInfoKey has copy, drop, store { ch_id: ID }

public struct RegistryCollateralInfoKey<phantom T> has copy, drop, store {}

public struct RegistryConfigKey has copy, drop, store {}

public struct AccountKey has copy, drop, store { account_id: u64 }

public struct OrderTicketKey has copy, drop, store { ticket_id: ID }

public struct IntegratorConfigKey has copy, drop, store { integrator_id: u32 }

public struct IntegratorRegistrationKey has copy, drop, store { integrator_id: u32 }

public struct MarketVaultKey has copy, drop, store {}

public struct PositionKey has copy, drop, store { account_id: u64 }

public struct MarginRatioProposalKey has copy, drop, store {}

public struct SettlementPricesKey has copy, drop, store {}

public struct AsksMapKey has copy, drop, store {}

public struct BidsMapKey has copy, drop, store {}

public struct VendorClearingHouseKey<phantom VendorKey> has copy, drop, store {}

public struct VendorRegistrationOpenKey has copy, drop, store {}

public struct FrozenVersionKey has copy, drop, store {}

public struct AuthorizedExtensionKey<phantom W> has copy, drop, store {}

// === Functions ===

public(package) fun registry_market_info(ch_id: ID): RegistryMarketInfoKey {
    RegistryMarketInfoKey { ch_id }
}

public(package) fun registry_collateral_info<T>(): RegistryCollateralInfoKey<T> {
    RegistryCollateralInfoKey {}
}

public(package) fun registry_config(): RegistryConfigKey {
    RegistryConfigKey {}
}

public(package) fun account(account_id: u64): AccountKey {
    AccountKey { account_id }
}

public(package) fun order_ticket(ticket_id: ID): OrderTicketKey {
    OrderTicketKey { ticket_id }
}

public(package) fun integrator_config(integrator_id: u32): IntegratorConfigKey {
    IntegratorConfigKey { integrator_id }
}

public(package) fun integrator_registration(integrator_id: u32): IntegratorRegistrationKey {
    IntegratorRegistrationKey { integrator_id }
}

public(package) fun market_vault(): MarketVaultKey {
    MarketVaultKey {}
}

public(package) fun position(account_id: u64): PositionKey {
    PositionKey { account_id }
}

public(package) fun margin_ratio_proposal(): MarginRatioProposalKey {
    MarginRatioProposalKey {}
}

public(package) fun settlement_prices(): SettlementPricesKey {
    SettlementPricesKey {}
}

public(package) fun asks_map(): AsksMapKey {
    AsksMapKey {}
}

public(package) fun bids_map(): BidsMapKey {
    BidsMapKey {}
}

public(package) fun vendor_clearing_house_key<VendorKey>(): VendorClearingHouseKey<VendorKey> {
    VendorClearingHouseKey {}
}

public(package) fun vendor_registration_open(): VendorRegistrationOpenKey {
    VendorRegistrationOpenKey {}
}

public(package) fun frozen_version(): FrozenVersionKey {
    FrozenVersionKey {}
}

public(package) fun authorized_extension<W>(): AuthorizedExtensionKey<W> {
    AuthorizedExtensionKey {}
}
