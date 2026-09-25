// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::keys;

// === Types ===

public struct AccountCapKey has copy, drop, store {}

public struct OwnerLockedLpCoinKey has copy, drop, store {}

public struct OwnerFeesKey has copy, drop, store {}

public struct ActiveAssistantCountKey has copy, drop, store {}

public struct VaultRecordKey has copy, drop, store { vault_id: ID }

public struct UserLpCoinRecordKey has copy, drop, store { user_lp_coin_id: ID }

public struct WithdrawRequestKey has copy, drop, store { sender: address }

public struct VaultMetadataKey has copy, drop, store {}

public struct FrozenVersionKey has copy, drop, store {}

// === Functions ===

public(package) fun owner_user_lp_coin_key(): OwnerLockedLpCoinKey {
    OwnerLockedLpCoinKey {}
}

public(package) fun owner_fees_key(): OwnerFeesKey {
    OwnerFeesKey {}
}

public(package) fun active_assistant_count_key(): ActiveAssistantCountKey {
    ActiveAssistantCountKey {}
}

public(package) fun vault_record_key(vault_id: ID): VaultRecordKey {
    VaultRecordKey { vault_id }
}

public(package) fun user_lp_coin_record_key(user_lp_coin_id: ID): UserLpCoinRecordKey {
    UserLpCoinRecordKey { user_lp_coin_id }
}

public(package) fun account_cap_key(): AccountCapKey {
    AccountCapKey {}
}

public(package) fun withdraw_request(sender: address): WithdrawRequestKey {
    WithdrawRequestKey { sender }
}

public(package) fun vault_metadata_key(): VaultMetadataKey {
    VaultMetadataKey {}
}

public(package) fun frozen_version_key(): FrozenVersionKey {
    FrozenVersionKey {}
}
