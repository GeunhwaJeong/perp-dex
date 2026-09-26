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
