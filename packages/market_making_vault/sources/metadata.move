// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module market_making_vault::metadata;

use haneul::derived_object;
use haneul::vec_map::{Self, VecMap};
use market_making_vault::events;
use market_making_vault::keys;
use std::ascii::String;

// === Errors and constants (original names from the published interface) ===

#[error(code = 0)]
const EVaultMetadataCapAlreadyCreated: vector<u8> = b"The `VaultMetadata` has already been created for the given `Vault`.";

// === Types ===

public struct VaultMetadata<phantom LpCoin> has key, store {
    id: UID,
    vault_id: ID,
    name: String,
    description: String,
    curator_name: Option<String>,
    curator_url: Option<String>,
    curator_logo_url: Option<String>,
    extra_fields: VecMap<String, String>,
}

// === Functions ===

public(package) fun new<LpCoin>(
    vault_id: &mut UID,
    name: String,
    description: String,
    curator_name: Option<String>,
    curator_url: Option<String>,
    curator_logo_url: Option<String>,
    mut extra_field_keys: Option<vector<String>>,
    mut extra_field_values: Option<vector<String>>,
): VaultMetadata<LpCoin> {
    let key = keys::vault_metadata_key();
    assert!(!derived_object::exists(vault_id, key), EVaultMetadataCapAlreadyCreated);

    let field_keys = extra_field_keys.extract_or!(vector[]);
    let field_values = extra_field_values.extract_or!(vector[]);
    VaultMetadata {
        id: derived_object::claim(vault_id, key),
        vault_id: vault_id.to_inner(),
        name,
        description,
        curator_name,
        curator_url,
        curator_logo_url,
        extra_fields: vec_map::from_keys_values(field_keys, field_values),
    }
}

public(package) fun set_name<LpCoin>(metadata: &mut VaultMetadata<LpCoin>, name: String) {
    metadata.name = name;
    events::emit_update_vault_metadata(metadata.vault_id, b"name".to_string(), name.to_string())
}

public(package) fun set_description<LpCoin>(
    metadata: &mut VaultMetadata<LpCoin>,
    description: String,
) {
    metadata.description = description;
    events::emit_update_vault_metadata(
        metadata.vault_id,
        b"description".to_string(),
        description.to_string(),
    )
}

public(package) fun set_curator_name<LpCoin>(
    metadata: &mut VaultMetadata<LpCoin>,
    curator_name: String,
) {
    metadata.curator_name = option::some(curator_name);
    events::emit_update_vault_metadata(
        metadata.vault_id,
        b"curator_name".to_string(),
        curator_name.to_string(),
    )
}

public(package) fun set_curator_url<LpCoin>(
    metadata: &mut VaultMetadata<LpCoin>,
    curator_url: String,
) {
    metadata.curator_url = option::some(curator_url);
    events::emit_update_vault_metadata(
        metadata.vault_id,
        b"curator_url".to_string(),
        curator_url.to_string(),
    )
}

public(package) fun set_curator_logo_url<LpCoin>(
    metadata: &mut VaultMetadata<LpCoin>,
    curator_logo_url: String,
) {
    metadata.curator_logo_url = option::some(curator_logo_url);
    events::emit_update_vault_metadata(
        metadata.vault_id,
        b"curator_logo_url".to_string(),
        curator_logo_url.to_string(),
    )
}

public(package) fun set_extra_field<LpCoin>(
    metadata: &mut VaultMetadata<LpCoin>,
    key: String,
    value: String,
) {
    let extra_fields = &mut metadata.extra_fields;
    if (!extra_fields.contains(&copy key)) extra_fields.insert(key, value)
    else *extra_fields.get_mut(&copy key) = value;
    events::emit_update_vault_metadata(metadata.vault_id, key.to_string(), value.to_string())
}

public(package) fun vault_id<LpCoin>(metadata: &VaultMetadata<LpCoin>): ID {
    metadata.vault_id
}
