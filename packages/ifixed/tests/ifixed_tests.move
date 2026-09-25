// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `ifixed` against a sign-and-magnitude reference implementation.
///
/// `ifixed` stores signed 18-decimal fixed-point numbers as 256-bit two's complement and
/// implements every operation with bit tricks. The reference here does the same arithmetic the
/// obvious way (a sign flag and a magnitude), and the tests check the two agree on hand-picked
/// edge cases and on pseudo-random operands, including the rounding direction of every
/// multiplication and division variant.
#[test_only]
module ifixed::ifixed_tests;

use ifixed::ifixed as fx;

const ONE: u256 = 1_000_000_000_000_000_000;
const HALF: u256 = 500_000_000_000_000_000;
const GB: u256 = 1 << 255;
const MAX: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
const OVERFLOW: u64 = 12001;

// === Reference implementation ===

/// Splits a two's complement value into (is_negative, magnitude).
fun sm(x: u256): (bool, u256) {
    if (x >= GB) (true, (x ^ MAX) + 1) else (false, x)
}

/// Whether a sign-and-magnitude value fits into 256-bit two's complement.
fun fits(neg: bool, mag: u256): bool {
    if (neg) mag <= GB else mag < GB
}

/// Encodes a sign-and-magnitude value. Zero is always encoded as 0.
fun enc(neg: bool, mag: u256): u256 {
    assert!(fits(neg, mag));
    if (mag == 0) return 0;
    if (neg) (mag ^ MAX) + 1 else mag
}

fun ceil_div(a: u256, b: u256): u256 {
    if (a == 0) 0 else (a - 1) / b + 1
}

/// Rounding modes for a signed quotient `sign * (num / den)`.
const FLOOR: u8 = 0; // toward negative infinity
const TRUNC: u8 = 1; // toward zero
const CEIL: u8 = 2; // toward positive infinity
const AWAY: u8 = 3; // away from zero

fun round(neg: bool, num: u256, den: u256, mode: u8): u256 {
    let mag_up = if (mode == AWAY) true
    else if (mode == TRUNC) false
    else if (mode == CEIL) !neg
    else neg;
    enc(neg, if (mag_up) ceil_div(num, den) else num / den)
}

/// Returns (fits, result) of the exact signed sum.
fun ref_add(x: u256, y: u256): (bool, u256) {
    let (xn, xm) = sm(x);
    let (yn, ym) = sm(y);
    if (xn == yn) {
        if (xm > MAX - ym) return (false, 0);
        let m = xm + ym;
        if (!fits(xn, m)) return (false, 0);
        (true, enc(xn, m))
    } else if (xm >= ym) {
        (true, enc(xn, xm - ym))
    } else {
        (true, enc(yn, ym - xm))
    }
}

fun ref_neg(x: u256): (bool, u256) {
    let (n, m) = sm(x);
    if (m == 0) return (true, 0);
    if (!fits(!n, m)) return (false, 0);
    (true, enc(!n, m))
}

fun ref_sub(x: u256, y: u256): (bool, u256) {
    let (ok, ny) = ref_neg(y);
    if (!ok) {
        // y == min_value: x - y = x + 2^255, which only fits for x < 0.
        let (xn, xm) = sm(x);
        if (!xn) return (false, 0);
        return (true, enc(false, GB - xm))
    };
    ref_add(x, ny)
}

fun ref_mul(x: u256, y: u256, mode: u8): u256 {
    let (xn, xm) = sm(x);
    let (yn, ym) = sm(y);
    round(xn != yn, xm * ym, ONE, mode)
}

fun ref_div(x: u256, y: u256, mode: u8): u256 {
    let (xn, xm) = sm(x);
    let (yn, ym) = sm(y);
    round(xn != yn, xm * ONE, ym, mode)
}

fun ref_lt(x: u256, y: u256): bool {
    let (xn, xm) = sm(x);
    let (yn, ym) = sm(y);
    if (xn != yn) return xn;
    if (xn) xm > ym else xm < ym
}

// === Pseudo-random operands ===

fun next(seed: &mut u64): u64 {
    let mut s = *seed;
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    *seed = s;
    s
}

/// A random value whose magnitude has at most `max_bits` bits, with a random sign. One draw in
/// eight is an edge value instead.
fun rand(seed: &mut u64, max_bits: u8): u256 {
    let r = next(seed);
    if (r % 8 == 0) {
        let edges = vector[0, 1, ONE, ONE - 1, ONE + 1, HALF, GB - 1, MAX, GB, GB + 1, MAX - ONE];
        let e = edges[((r >> 8) as u64) % edges.length()];
        let (n, m) = sm(e);
        let mask = if (max_bits >= 255) MAX else (1 << max_bits) - 1;
        return enc(n && m <= GB, m & mask)
    };
    let bits = (((next(seed) % ((max_bits as u64) + 1)) as u8));
    let mut mag = (next(seed) as u256)
        | ((next(seed) as u256) << 64)
        | ((next(seed) as u256) << 128)
        | ((next(seed) as u256) << 192);
    if (bits < 255) mag = mag & ((1 << bits) - 1);
    if (mag == 0) return 0;
    let neg = next(seed) % 2 == 0;
    if (neg) enc(true, mag) else enc(false, mag & (GB - 1))
}

const ITERATIONS: u64 = 400;

// === Constants and conversions ===

#[test]
fun constants() {
    assert!(fx::one() == ONE);
    assert!(fx::neg_one() == MAX);
    assert!(fx::min_value() == GB);
    assert!(fx::max_value() == GB - 1);
    assert!(fx::overflow_error() == OVERFLOW);
    assert!(fx::is_cast_safe(GB - 1) && !fx::is_cast_safe(GB));
    // neg_one() is the raw encoding of -1, i.e. -1e-18 as a fixed-point value.
    assert!(fx::add(1, fx::neg_one()) == 0);
    assert!(fx::add(fx::one(), fx::neg(fx::one())) == 0);
}

#[test]
fun decimal_scalars() {
    assert!(fx::decimal_scalar_from_decimals(0) == 1_000_000_000_000_000_000);
    assert!(fx::decimal_scalar_from_decimals(6) == 1_000_000_000_000);
    assert!(fx::decimal_scalar_from_decimals(9) == 1_000_000_000);
    assert!(fx::decimal_scalar_from_decimals(18) == 1);
    let mut d = 0;
    while (d <= 18) {
        let s = fx::decimal_scalar_from_decimals(d);
        assert!(fx::from_balance(1, (s as u256)) * (std::u64::pow(10, (d as u8)) as u256) == ONE);
        d = d + 1;
    }
}

#[test, expected_failure(abort_code = 0, location = ifixed::ifixed)]
fun decimal_scalar_too_many_decimals() {
    fx::decimal_scalar_from_decimals(19);
}

#[test]
fun conversions_round_trip() {
    assert!(fx::from_u64(7) == 7 * ONE);
    assert!(fx::to_u64(7 * ONE + ONE - 1) == 7);
    assert!(fx::from_u128(7) == 7 * ONE);
    assert!(fx::to_u128(7 * ONE + 1) == 7);
    assert!(fx::from_u256(7) == 7 * ONE);
    assert!(fx::to_u256(7 * ONE) == 7);
    assert!(fx::from_u64fraction(1, 3) == 333_333_333_333_333_333);
    assert!(fx::from_u128fraction(2, 3) == 666_666_666_666_666_666);
    assert!(fx::from_u256fraction(1, 4) == 250_000_000_000_000_000);
    // Balances with 6 decimals scale by 1e12.
    assert!(fx::from_balance(1_500_000, 1_000_000_000_000) == ONE + HALF);
    assert!(fx::to_balance(ONE + HALF + 1, 1_000_000_000_000) == 1_500_000);
    assert!(fx::from_u128balance(1_500_000, 1_000_000_000_000) == ONE + HALF);
    assert!(fx::to_u128balance(ONE + HALF, 1_000_000_000_000) == 1_500_000);
    assert!(fx::from_u256balance(3, 1_000_000_000) == 3_000_000_000);
    assert!(fx::to_u256balance(3_000_000_001, 1_000_000_000) == 3);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun to_u64_rejects_negative() {
    fx::to_u64(fx::neg_one());
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun to_balance_rejects_negative() {
    fx::to_balance(fx::neg_one(), 1);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun from_u256_rejects_too_large() {
    fx::from_u256(GB / ONE + 1);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun from_balance_rejects_too_large() {
    fx::from_balance(0xffff_ffff_ffff_ffff, GB / 0xffff_ffff_ffff_ffff + 1);
}

// === Sign, negation, comparison ===

#[test]
fun sign_helpers() {
    assert!(!fx::is_neg(0) && !fx::is_neg(GB - 1) && fx::is_neg(GB) && fx::is_neg(MAX));
    assert!(fx::same_sign(0, GB - 1) && fx::same_sign(MAX, GB));
    assert!(fx::diff_sign(0, MAX) && fx::diff_sign(GB, 1));
    assert!(fx::neg(0) == 0);
    assert!(fx::neg(ONE) == MAX - ONE + 1);
    assert!(fx::neg(fx::neg(ONE)) == ONE);
    // -(min_value + 1) = max_value.
    assert!(fx::neg(GB + 1) == GB - 1);
    assert!(fx::abs(0) == 0 && fx::abs(ONE) == ONE && fx::abs(MAX) == 1);
    assert!(fx::abs(GB + 1) == GB - 1);
}

#[test, expected_failure(arithmetic_error, location = ifixed::ifixed)]
fun neg_min_value_aborts() {
    fx::neg(GB);
}

#[test, expected_failure(arithmetic_error, location = ifixed::ifixed)]
fun abs_min_value_aborts() {
    fx::abs(GB);
}

#[test]
fun comparisons_are_signed() {
    // Ascending: min, -1, 0, 1, max.
    let sorted = vector[GB, MAX, 0, 1, GB - 1];
    let mut i = 0;
    while (i < sorted.length()) {
        let mut j = 0;
        while (j < sorted.length()) {
            let (a, b) = (sorted[i], sorted[j]);
            assert!(fx::less_than(a, b) == (i < j));
            assert!(fx::less_than_eq(a, b) == (i <= j));
            assert!(fx::greater_than(a, b) == (i > j));
            assert!(fx::greater_than_eq(a, b) == (i >= j));
            assert!(fx::max(a, b) == if (i >= j) a else b);
            assert!(fx::min(a, b) == if (i <= j) a else b);
            j = j + 1;
        };
        i = i + 1;
    }
}

#[test]
fun comparisons_fuzz() {
    let mut seed = 0x9E37_79B9_7F4A_7C15;
    let mut i = 0;
    while (i < ITERATIONS) {
        let (x, y) = (rand(&mut seed, 255), rand(&mut seed, 255));
        let lt = ref_lt(x, y);
        let gt = ref_lt(y, x);
        assert!(fx::less_than(x, y) == lt);
        assert!(fx::greater_than(x, y) == gt);
        assert!(fx::less_than_eq(x, y) == !gt);
        assert!(fx::greater_than_eq(x, y) == !lt);
        assert!(fx::max(x, y) == if (lt) y else x);
        assert!(fx::min(x, y) == if (lt) x else y);
        i = i + 1;
    }
}

// === Addition and subtraction ===

#[test]
fun add_sub_edges() {
    assert!(fx::add(GB - 1, MAX) == GB - 2); // max + (-1)
    assert!(fx::add(GB, 0) == GB); // min + 0
    assert!(fx::add(GB + 1, MAX) == GB); // (min + 1) + (-1) = min
    assert!(fx::add(MAX, 1) == 0); // -1 + 1
    assert!(fx::add(MAX, MAX) == MAX - 1); // -1 + -1 = -2
    assert!(fx::sub(0, 1) == MAX);
    assert!(fx::sub(GB - 1, GB - 1) == 0);
    assert!(fx::sub(GB, 0) == GB);
    assert!(fx::sub(MAX, MAX) == 0);
    assert!(fx::sub(GB + 1, 1) == GB); // (min + 1) - 1 = min
    assert!(fx::sub(MAX, GB) == GB - 1); // -1 - min = max
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun add_overflows_positive() {
    fx::add(GB - 1, 1);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun add_overflows_negative() {
    fx::add(GB, MAX);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun sub_overflows_positive() {
    fx::sub(GB - 1, MAX);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun sub_overflows_negative() {
    fx::sub(GB, 1);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun sub_zero_minus_min_overflows() {
    fx::sub(0, GB);
}

#[test]
fun add_sub_fuzz() {
    let mut seed = 0xD1B5_4A32_D192_ED03;
    let mut i = 0;
    let mut checked = 0;
    while (i < ITERATIONS) {
        let (x, y) = (rand(&mut seed, 255), rand(&mut seed, 255));
        let (ok, sum) = ref_add(x, y);
        if (ok) {
            assert!(fx::add(x, y) == sum);
            assert!(fx::add(y, x) == sum);
            // (x + y) - y == x whenever the subtraction is representable.
            let (ok_back, back) = ref_sub(sum, y);
            if (ok_back) assert!(fx::sub(sum, y) == back && back == x);
            checked = checked + 1;
        };
        let (ok, diff) = ref_sub(x, y);
        if (ok) {
            assert!(fx::sub(x, y) == diff);
            checked = checked + 1;
        };
        i = i + 1;
    };
    assert!(checked > ITERATIONS);
}

// === Multiplication ===

#[test]
fun mul_rounding_table() {
    // 1e-18 * 0.5 = 5e-19: below the resolution, the rounding mode decides.
    let (tiny, neg_tiny) = (1, MAX);
    assert!(fx::mul(tiny, HALF) == 0);
    assert!(fx::mul_toward_zero(tiny, HALF) == 0);
    assert!(fx::mul_up(tiny, HALF) == 1);
    assert!(fx::mul_away_from_zero(tiny, HALF) == 1);
    assert!(fx::mul(neg_tiny, HALF) == MAX); // floor(-0.5e-18) = -1e-18
    assert!(fx::mul_toward_zero(neg_tiny, HALF) == 0);
    assert!(fx::mul_up(neg_tiny, HALF) == 0);
    assert!(fx::mul_away_from_zero(neg_tiny, HALF) == MAX);
    // Negative times negative is positive; exact products are unaffected by the mode.
    let neg_two = fx::neg(2 * ONE);
    assert!(fx::mul(neg_two, neg_two) == 4 * ONE);
    assert!(fx::mul(neg_two, 3 * ONE) == fx::neg(6 * ONE));
    assert!(fx::mul_up(neg_two, 3 * ONE) == fx::neg(6 * ONE));
    // Zero times anything is zero, including negative operands.
    assert!(fx::mul(0, MAX) == 0 && fx::mul_up(0, MAX) == 0);
    assert!(fx::mul_toward_zero(0, MAX) == 0 && fx::mul_away_from_zero(0, MAX) == 0);
    assert!(fx::mul(MAX, 0) == 0);
}

#[test]
fun mul_fuzz() {
    let mut seed = 0x2545_F491_4F6C_DD1D;
    let mut i = 0;
    while (i < ITERATIONS) {
        // Magnitudes below 2^126 keep the raw product inside u256.
        let (x, y) = (rand(&mut seed, 126), rand(&mut seed, 126));
        assert!(fx::mul(x, y) == ref_mul(x, y, FLOOR));
        assert!(fx::mul(y, x) == ref_mul(x, y, FLOOR));
        assert!(fx::mul_toward_zero(x, y) == ref_mul(x, y, TRUNC));
        assert!(fx::mul_up(x, y) == ref_mul(x, y, CEIL));
        assert!(fx::mul_away_from_zero(x, y) == ref_mul(x, y, AWAY));
        // The modes bracket the exact product in the expected order.
        assert!(fx::less_than_eq(fx::mul(x, y), fx::mul_up(x, y)));
        assert!(fx::less_than_eq(
            fx::abs(fx::mul_toward_zero(x, y)),
            fx::abs(fx::mul_away_from_zero(x, y)),
        ));
        i = i + 1;
    }
}

#[test]
fun mul_i256_is_unscaled() {
    assert!(fx::mul_i256(3, 4) == 12);
    assert!(fx::mul_i256(MAX, 4) == fx::neg(4));
    assert!(fx::mul_i256(MAX, MAX) == 1);
    assert!(fx::mul_i256(GB + 1, 1) == GB + 1);
    // The result may be exactly min_value.
    assert!(fx::mul_i256(fx::neg(1 << 254), 2) == GB);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun mul_i256_overflows_positive() {
    fx::mul_i256(1 << 254, 2);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun mul_i256_overflows_negative() {
    fx::mul_i256(fx::neg(1 << 254), 3);
}

// === Division ===

#[test]
fun div_rounding_table() {
    let third_num = 1;
    let three = 3 * ONE;
    // 1e-18 / 3 = 3.33e-19.
    assert!(fx::div(third_num, three) == 0);
    assert!(fx::div_toward_zero(third_num, three) == 0);
    assert!(fx::div_up(third_num, three) == 1);
    assert!(fx::div_away_from_zero(third_num, three) == 1);
    assert!(fx::div(MAX, three) == MAX);
    assert!(fx::div_toward_zero(MAX, three) == 0);
    assert!(fx::div_up(MAX, three) == 0);
    assert!(fx::div_away_from_zero(MAX, three) == MAX);
    // 1 / 3 and -1 / 3 at full resolution.
    assert!(fx::div(ONE, three) == 333_333_333_333_333_333);
    assert!(fx::div_up(ONE, three) == 333_333_333_333_333_334);
    assert!(fx::div(MAX - ONE + 1, three) == fx::neg(333_333_333_333_333_334));
    assert!(fx::div_up(MAX - ONE + 1, three) == fx::neg(333_333_333_333_333_333));
    // Exact quotients and zero numerators.
    assert!(fx::div(6 * ONE, fx::neg(2 * ONE)) == fx::neg(3 * ONE));
    assert!(fx::div(0, MAX) == 0 && fx::div_up(0, MAX) == 0);
    assert!(fx::div_toward_zero(0, MAX) == 0 && fx::div_away_from_zero(0, MAX) == 0);
}

#[test, expected_failure(arithmetic_error, location = ifixed::ifixed)]
fun div_by_zero_aborts() {
    fx::div(ONE, 0);
}

#[test, expected_failure(arithmetic_error, location = ifixed::ifixed)]
fun div_up_by_zero_aborts() {
    fx::div_up(ONE, 0);
}

#[test, expected_failure(abort_code = OVERFLOW, location = ifixed::ifixed)]
fun div_overflows() {
    // 2^196 * 1e18 still fits in u256 but the quotient does not fit in 255 bits.
    fx::div(1 << 196, 1);
}

#[test]
fun div_fuzz() {
    let mut seed = 0x0000_0000_5DEE_CE66;
    let mut i = 0;
    while (i < ITERATIONS) {
        // |x| * 1e18 stays inside u256 for magnitudes below 2^190, and every quotient then fits.
        let x = rand(&mut seed, 190);
        let mut y = rand(&mut seed, 255);
        if (y == 0) y = 1;
        assert!(fx::div(x, y) == ref_div(x, y, FLOOR));
        assert!(fx::div_toward_zero(x, y) == ref_div(x, y, TRUNC));
        assert!(fx::div_up(x, y) == ref_div(x, y, CEIL));
        assert!(fx::div_away_from_zero(x, y) == ref_div(x, y, AWAY));
        assert!(fx::less_than_eq(fx::div(x, y), fx::div_up(x, y)));
        i = i + 1;
    }
}

#[test]
fun mul_div_round_trip() {
    let mut seed = 0x1234_5678_9ABC_DEF0;
    let mut i = 0;
    while (i < ITERATIONS) {
        let x = rand(&mut seed, 100);
        let mut y = rand(&mut seed, 60);
        if (y == 0) y = ONE;
        // (x * y) / y is within one unit of x, on the floor side.
        let back = fx::div(fx::mul(x, y), y);
        let err = fx::abs(fx::sub(back, x));
        assert!(fx::less_than_eq(err, fx::div_up(2 * ONE, fx::abs(y)) + 1));
        i = i + 1;
    }
}

// === close_enough ===

#[test]
fun close_enough_relative_tolerance() {
    let one_percent = fx::from_u64fraction(1, 100);
    assert!(fx::close_enough(100 * ONE, 100 * ONE, 0));
    assert!(fx::close_enough(100 * ONE, 99 * ONE, one_percent));
    assert!(fx::close_enough(99 * ONE, 100 * ONE, one_percent));
    assert!(!fx::close_enough(100 * ONE, 98 * ONE, one_percent));
    assert!(fx::close_enough(fx::neg(100 * ONE), fx::neg(99 * ONE), one_percent));
    assert!(!fx::close_enough(100 * ONE, fx::neg(100 * ONE), one_percent));
    assert!(fx::close_enough(0, 0, 0));
}
