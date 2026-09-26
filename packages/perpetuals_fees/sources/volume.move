// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// A rolling window of per-epoch volume. Bucket `epoch % length` holds the volume of the epoch
/// recorded in `bucket_epochs`; a bucket whose epoch has fallen out of the window is ignored on
/// read and overwritten on the next write, so no rotation step is needed.
module perpetuals_fees::volume;

use ifixed::ifixed;

const EWindowTooShort: u64 = 1;

public struct VolumeWindow has store {
    length: u64,
    buckets: vector<u256>,
    bucket_epochs: vector<u64>,
}

public(package) fun new(length: u64): VolumeWindow {
    assert!(length > 0, EWindowTooShort);
    let mut buckets = vector[];
    let mut bucket_epochs = vector[];
    length.do!(|_| {
        buckets.push_back(0);
        bucket_epochs.push_back(0);
    });
    VolumeWindow { length, buckets, bucket_epochs }
}

/// Adds `notional` to `epoch`'s bucket. An epoch older than what its bucket already holds is
/// dropped: it fell out of the window before it was merged.
public(package) fun record(window: &mut VolumeWindow, epoch: u64, notional: u256) {
    let i = epoch % window.length;
    if (window.bucket_epochs[i] > epoch) return;
    if (window.bucket_epochs[i] != epoch) {
        let bucket_epoch = &mut window.bucket_epochs[i];
        *bucket_epoch = epoch;
        let bucket = &mut window.buckets[i];
        *bucket = 0;
    };
    let bucket = &mut window.buckets[i];
    *bucket = ifixed::add(*bucket, notional);
}

/// Adds every bucket of `from` still inside the window at `epoch` into `into`.
public(package) fun merge(into: &mut VolumeWindow, from: &VolumeWindow, epoch: u64) {
    let mut i = 0;
    while (i < from.length) {
        let bucket_epoch = from.bucket_epochs[i];
        if (from.buckets[i] != 0 && bucket_epoch <= epoch && epoch - bucket_epoch < into.length) {
            into.record(bucket_epoch, from.buckets[i]);
        };
        i = i + 1;
    };
}

/// Volume over the `length` epochs ending at `epoch` (inclusive).
public fun total(window: &VolumeWindow, epoch: u64): u256 {
    let mut sum = 0;
    let mut i = 0;
    while (i < window.length) {
        let bucket_epoch = window.bucket_epochs[i];
        // A fresh window has epoch 0 in every bucket; epoch 0 itself counts only inside the window.
        if (bucket_epoch <= epoch && epoch - bucket_epoch < window.length) {
            sum = ifixed::add(sum, window.buckets[i]);
        };
        i = i + 1;
    };
    sum
}

public fun length(window: &VolumeWindow): u64 { window.length }

public(package) fun destroy(window: VolumeWindow) {
    let VolumeWindow { .. } = window;
}
