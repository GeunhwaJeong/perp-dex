// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module perpetuals_fees::volume_tests;

use perpetuals_fees::volume;

#[test]
fun the_window_keeps_the_last_length_epochs() {
    let mut window = volume::new(3);
    window.record(10, 100);
    window.record(11, 10);
    window.record(12, 1);
    assert!(window.total(12) == 111);
    // Epoch 10 falls out at epoch 13 even before anything is recorded there.
    assert!(window.total(13) == 11);
    window.record(13, 1000);
    assert!(window.total(13) == 1011);
    // Recording twice in an epoch accumulates.
    window.record(13, 1);
    assert!(window.total(13) == 1012);
    // A bucket reused for a later epoch forgets the old one.
    window.record(16, 7);
    assert!(window.total(16) == 7);
    window.destroy();
}

#[test]
fun a_fresh_window_only_counts_epoch_zero_inside_the_window() {
    let mut window = volume::new(2);
    window.record(0, 5);
    assert!(window.total(0) == 5);
    assert!(window.total(1) == 5);
    assert!(window.total(2) == 0);
    window.destroy();
}

#[test]
fun merging_carries_buckets_inside_the_window_and_drops_the_rest() {
    let mut into = volume::new(3);
    let mut from = volume::new(3);
    from.record(10, 100);
    from.record(11, 10);
    from.record(12, 1);
    // At epoch 13 the epoch-10 bucket is outside the window and is not carried over.
    into.record(13, 1000);
    into.merge(&from, 13);
    assert!(into.total(13) == 1011);
    // Merging again adds again; the caller is expected to discard the source.
    into.merge(&from, 13);
    assert!(into.total(13) == 1022);
    into.destroy();
    from.destroy();
}

#[test]
fun recording_an_epoch_older_than_its_bucket_is_ignored() {
    let mut window = volume::new(2);
    window.record(5, 7);
    // Epoch 3 maps to the bucket that already holds epoch 5.
    window.record(3, 100);
    assert!(window.total(5) == 7);
    window.destroy();
}
