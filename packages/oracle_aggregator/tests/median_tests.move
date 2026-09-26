// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module oracle_aggregator::median_tests;

use oracle_aggregator::price;

#[test]
fun one_price_is_its_own_median() {
    assert!(price::median_of(vector[7]) == 7);
}

#[test]
fun two_prices_meet_in_the_middle() {
    assert!(price::median_of(vector[100, 200]) == 150);
    assert!(price::median_of(vector[200, 100]) == 150);
    // Rounded down; the sum is taken in 256 bits so the largest prices cannot overflow.
    assert!(price::median_of(vector[100, 201]) == 150);
    let max = 340_282_366_920_938_463_463_374_607_431_768_211_455u128;
    assert!(price::median_of(vector[max, max]) == max);
    assert!(price::median_of(vector[max, max - 1]) == max - 1);
}

#[test]
fun three_prices_take_the_middle_one() {
    assert!(price::median_of(vector[300, 100, 200]) == 200);
    assert!(price::median_of(vector[100, 100, 900]) == 100);
    assert!(price::median_of(vector[900, 100, 900]) == 900);
}

#[test, expected_failure(abort_code = price::ENoValidPrices)]
fun no_prices_abort() {
    price::median_of(vector[]);
}

#[test, expected_failure(abort_code = price::ETooManyPriceFeedsForMedian)]
fun four_prices_abort() {
    price::median_of(vector[1, 2, 3, 4]);
}
