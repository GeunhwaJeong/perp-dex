// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

module ifixed::ifixed;

// Signed 18-decimal fixed point numbers stored in a `u256` as 256-bit two's complement.
//
// Bit tricks used throughout the module:
// - `x >= GREATEST_BIT` tests the sign bit, i.e. whether `x` is negative.
// - `x ^ y < GREATEST_BIT` holds when `x` and `y` have the same sign.
// - `x ^ GREATEST_BIT` flips the sign bit, which maps signed order onto unsigned order.
// - `(x ^ MAX_U256) + 1` flips every bit and adds one: the two's complement negation of a
//   nonzero `x`.
// - `(GREATEST_BIT - m) ^ GREATEST_BIT` turns a magnitude `m` into `-m`, aborting when
//   `m > 2^255` (the magnitude does not fit in a negative value).

// === Errors and constants ===

const ONE: u256 = 1__000_000_000_000_000_000;
// All 256 bits set: the raw two's complement encoding of -1. Not part of the published
// interface; the name is ours.
const MAX_U256: u256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935u256;
const GREATEST_BIT: u256 = (1 << 255);
const NOT_GREATEST_BIT: u256 = (1 << 255) - 1;
const EOverflow: u64 = 12001;
const EInvalidDecimals: u64 = 0;
const SCALING_FACTORS: vector<u64> = vector<u64>[
    1__000_000_000_000_000_000,
    0__100_000_000_000_000_000,
    0__010_000_000_000_000_000,
    0__001_000_000_000_000_000,
    0__000_100_000_000_000_000,
    0__000_010_000_000_000_000,
    0__000_001_000_000_000_000,
    0__000_000_100_000_000_000,
    0__000_000_010_000_000_000,
    0__000_000_001_000_000_000,
    0__000_000_000_100_000_000,
    0__000_000_000_010_000_000,
    0__000_000_000_001_000_000,
    0__000_000_000_000_100_000,
    0__000_000_000_000_010_000,
    0__000_000_000_000_001_000,
    0__000_000_000_000_000_100,
    0__000_000_000_000_000_010,
    0__000_000_000_000_000_001,
];

// === Functions ===

#[allow(implicit_const_copy)]
public fun decimal_scalar_from_decimals(decimals: u64): u64 {
    assert!(decimals <= 18, EInvalidDecimals);
    SCALING_FACTORS[decimals]
}

public fun one(): u256 {
    ONE
}

public fun neg_one(): u256 {
    MAX_U256
}

public fun min_value(): u256 {
    GREATEST_BIT
}

public fun max_value(): u256 {
    NOT_GREATEST_BIT
}

public fun overflow_error(): u64 {
    EOverflow
}

public fun is_cast_safe(x: u256): bool {
    x < GREATEST_BIT
}

public fun from_u64(a: u64): u256 {
    (a as u256) * ONE
}

public fun to_u64(x: u256): u64 {
    assert!(x < GREATEST_BIT, EOverflow);
    ((x / ONE) as u64)
}

public fun from_u64fraction(numerator: u64, denominator: u64): u256 {
    div(from_u64(numerator), from_u64(denominator))
}

public fun from_u128(a: u128): u256 {
    (a as u256) * ONE
}

public fun to_u128(x: u256): u128 {
    assert!(x < GREATEST_BIT, EOverflow);
    ((x / ONE) as u128)
}

public fun from_u128fraction(numerator: u128, denominator: u128): u256 {
    div(from_u128(numerator), from_u128(denominator))
}

public fun from_u256(x: u256): u256 {
    let fixed = x * ONE;
    assert!(fixed < GREATEST_BIT, EOverflow);
    fixed
}

public fun to_u256(x: u256): u256 {
    assert!(x < GREATEST_BIT, EOverflow);
    x / ONE
}

public fun from_u256fraction(numerator: u256, denominator: u256): u256 {
    div(from_u256(numerator), from_u256(denominator))
}

public fun from_balance(balance: u64, scaling_factor: u256): u256 {
    let fixed = (balance as u256) * scaling_factor;
    assert!(fixed < GREATEST_BIT, EOverflow);
    fixed
}

public fun to_balance(x: u256, scaling_factor: u256): u64 {
    assert!(x < GREATEST_BIT, EOverflow);
    ((x / scaling_factor) as u64)
}

public fun from_u128balance(balance: u128, scaling_factor: u256): u256 {
    let fixed = (balance as u256) * scaling_factor;
    assert!(fixed < GREATEST_BIT, EOverflow);
    fixed
}

public fun to_u128balance(x: u256, scaling_factor: u256): u128 {
    assert!(x < GREATEST_BIT, EOverflow);
    ((x / scaling_factor) as u128)
}

public fun from_u256balance(balance: u256, scaling_factor: u256): u256 {
    let fixed = balance * scaling_factor;
    assert!(fixed < GREATEST_BIT, EOverflow);
    fixed
}

public fun to_u256balance(x: u256, scaling_factor: u256): u256 {
    assert!(x < GREATEST_BIT, EOverflow);
    x / scaling_factor
}

public fun add(x: u256, y: u256): u256 {
    // Add the low 255 bits only. With equal signs the carry out of bit 254 must reproduce the
    // operands' sign bit, otherwise the sum overflowed. With opposite signs the sum cannot overflow
    // and its sign bit is the complement of that carry.
    let low_bits_sum = (x & NOT_GREATEST_BIT) + (y & NOT_GREATEST_BIT);
    if (x ^ y < GREATEST_BIT) {
        assert!(x ^ low_bits_sum < GREATEST_BIT, EOverflow);
        return low_bits_sum
    };
    low_bits_sum ^ GREATEST_BIT
}

public fun sub(x: u256, y: u256): u256 {
    let difference;
    if (x >= y) {
        difference = x - y;
    } else {
        difference = ((y - x) ^ MAX_U256) + 1;
    };
    // Only operands of opposite signs can overflow; the result must then keep the sign of `x`.
    assert!(x ^ y < GREATEST_BIT || x ^ difference < GREATEST_BIT, EOverflow);
    difference
}

// The multiplications and divisions work on magnitudes, round the magnitude according to the
// function's rounding mode, and negate the result when the operands have opposite signs.

public fun mul(x: u256, y: u256): u256 {
    let x_abs = if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x;
    let product = x_abs * (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT) {
        return product / ONE
    };
    if (product == 0) {
        return 0
    };
    (GREATEST_BIT - ((product - 1) / ONE + 1)) ^ GREATEST_BIT
}

public fun mul_toward_zero(x: u256, y: u256): u256 {
    let x_abs = if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x;
    let product = x_abs * (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT) {
        return product / ONE
    };
    (GREATEST_BIT - product / ONE) ^ GREATEST_BIT
}

public fun mul_up(x: u256, y: u256): u256 {
    let x_abs = if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x;
    let product = x_abs * (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT) {
        if (product == 0) {
            return 0
        };
        return (product - 1) / ONE + 1
    };
    (GREATEST_BIT - product / ONE) ^ GREATEST_BIT
}

public fun mul_away_from_zero(x: u256, y: u256): u256 {
    let x_abs = if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x;
    let product = x_abs * (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT) {
        if (product == 0) {
            return 0
        };
        return (product - 1) / ONE + 1
    };
    if (product == 0) {
        return 0
    };
    (GREATEST_BIT - ((product - 1) / ONE + 1)) ^ GREATEST_BIT
}

public fun div(x: u256, y: u256): u256 {
    if (x ^ y < GREATEST_BIT || x == 0) {
        let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x);
        let quotient = scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
        assert!(quotient < GREATEST_BIT, EOverflow);
        return quotient
    };
    let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x) - 1;
    (GREATEST_BIT - (scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y) + 1))
        ^ GREATEST_BIT
}

public fun div_toward_zero(x: u256, y: u256): u256 {
    let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x);
    let quotient = scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT || x == 0) {
        assert!(quotient < GREATEST_BIT, EOverflow);
        return quotient
    };
    (GREATEST_BIT - quotient) ^ GREATEST_BIT
}

public fun div_up(x: u256, y: u256): u256 {
    if (x == 0) {
        return x / y
    };
    if (x ^ y < GREATEST_BIT) {
        let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x) - 1;
        let quotient = scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y) + 1;
        assert!(quotient < GREATEST_BIT, EOverflow);
        return quotient
    };
    let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x);
    (GREATEST_BIT - scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y)) ^ GREATEST_BIT
}

public fun div_away_from_zero(x: u256, y: u256): u256 {
    if (x == 0) {
        return x / y
    };
    let scaled_x = ONE * (if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x) - 1;
    let quotient = scaled_x / (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y) + 1;
    if (x ^ y < GREATEST_BIT) {
        assert!(quotient < GREATEST_BIT, EOverflow);
        return quotient
    };
    (GREATEST_BIT - quotient) ^ GREATEST_BIT
}

public fun neg(x: u256): u256 {
    // Negate the low 255 bits and flip the sign bit. The addition aborts for `min_value()`, the one
    // value whose negation does not fit.
    ((x ^ NOT_GREATEST_BIT) + 1) ^ GREATEST_BIT
}

public fun abs(x: u256): u256 {
    if (x >= GREATEST_BIT) {
        return ((x ^ NOT_GREATEST_BIT) + 1) ^ GREATEST_BIT
    };
    x
}

public fun max(x: u256, y: u256): u256 {
    if (x ^ GREATEST_BIT < y ^ GREATEST_BIT) y else x
}

public fun min(x: u256, y: u256): u256 {
    if (x ^ GREATEST_BIT < y ^ GREATEST_BIT) x else y
}

public fun is_neg(x: u256): bool {
    x >= GREATEST_BIT
}

public fun same_sign(x: u256, y: u256): bool {
    x ^ y < GREATEST_BIT
}

public fun diff_sign(x: u256, y: u256): bool {
    x ^ y >= GREATEST_BIT
}

public fun greater_than(x: u256, y: u256): bool {
    x ^ GREATEST_BIT > y ^ GREATEST_BIT
}

public fun greater_than_eq(x: u256, y: u256): bool {
    x ^ GREATEST_BIT >= y ^ GREATEST_BIT
}

public fun less_than(x: u256, y: u256): bool {
    x ^ GREATEST_BIT < y ^ GREATEST_BIT
}

public fun less_than_eq(x: u256, y: u256): bool {
    x ^ GREATEST_BIT <= y ^ GREATEST_BIT
}

public fun close_enough(a: u256, b: u256, tolerance: u256): bool {
    let a_abs = abs(a);
    let b_abs = abs(b);
    if (less_than(a_abs, b_abs)) {
        return close_enough(b, a, tolerance)
    };
    // |a - b| / |a| <= tolerance, where |a| is the larger magnitude, checked without dividing.
    less_than_eq(from_u256(abs(sub(a, b))), mul_i256(a_abs, tolerance))
}

public fun mul_i256(x: u256, y: u256): u256 {
    let x_abs = if (x >= GREATEST_BIT) (x ^ MAX_U256) + 1 else x;
    let product = x_abs * (if (y >= GREATEST_BIT) (y ^ MAX_U256) + 1 else y);
    if (x ^ y < GREATEST_BIT) {
        assert!(product < GREATEST_BIT, EOverflow);
        return product
    };
    assert!(product <= GREATEST_BIT, EOverflow);
    (GREATEST_BIT - product) ^ GREATEST_BIT
}
