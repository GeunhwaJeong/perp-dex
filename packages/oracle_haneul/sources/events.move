// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

module oracle_aggregator_haneul_integration::events;

use haneul::event;

// === Types ===

public struct SetSigner has copy, drop {
    source_id: u16,
    public_key: vector<u8>,
    expires_at_ms: u64,
}

public struct RemovedSigner has copy, drop { source_id: u16, public_key: vector<u8> }

public struct SetMaxConfidenceBps has copy, drop {
    source_id: u16,
    old_max_confidence_bps: u64,
    new_max_confidence_bps: u64,
}

public struct SetMaxFutureDriftMs has copy, drop {
    source_id: u16,
    old_max_future_drift_ms: u64,
    new_max_future_drift_ms: u64,
}

// === Functions ===

public(package) fun set_signer(source_id: u16, public_key: vector<u8>, expires_at_ms: u64) {
    event::emit(SetSigner { source_id, public_key, expires_at_ms })
}

public(package) fun removed_signer(source_id: u16, public_key: vector<u8>) {
    event::emit(RemovedSigner { source_id, public_key })
}

public(package) fun set_max_confidence_bps(
    source_id: u16,
    old_max_confidence_bps: u64,
    new_max_confidence_bps: u64,
) {
    event::emit(SetMaxConfidenceBps { source_id, old_max_confidence_bps, new_max_confidence_bps })
}

public(package) fun set_max_future_drift_ms(
    source_id: u16,
    old_max_future_drift_ms: u64,
    new_max_future_drift_ms: u64,
) {
    event::emit(SetMaxFutureDriftMs { source_id, old_max_future_drift_ms, new_max_future_drift_ms })
}
