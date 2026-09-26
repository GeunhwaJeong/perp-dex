// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The fee schedule: volume tiers give absolute taker and maker rates, staking tiers give a
/// discount on top, and the two combine into the multipliers the perpetuals core applies to a
/// market's own rates. Rates are ifixed fractions of notional (0.045% is 0.00045 ifixed).
///
/// The schedule is written against reference base rates. A tier's multiplier is its rate over
/// the base rate, so a market that charges the base rates pays exactly the schedule; a market
/// with other rates is scaled in proportion. Every tier rate must be at or below the base
/// rate, which keeps every multiplier in [0, 1]: this package can only ever discount.
module perpetuals_fees::config;

use haneul::event;
use ifixed::ifixed;

// === Errors ===

const EWrongVersion: u64 = 1;
const EInvalidBaseFee: u64 = 2;
const ELengthMismatch: u64 = 3;
const EVolumeTiersNotAscending: u64 = 4;
const EFirstVolumeTierNotZero: u64 = 5;
const ETierFeeAboveBase: u64 = 6;
const EStakingTiersNotAscending: u64 = 7;
const EInvalidDiscount: u64 = 8;
const EInvalidTtl: u64 = 9;
const EInvalidWindow: u64 = 10;

// === Constants ===

const VERSION: u64 = 1;
const MAX_WINDOW_EPOCHS: u64 = 64;

// === Types ===

public struct FeeSchedule has key {
    id: UID,
    version: u64,
    base_taker_fee: u256,
    base_maker_fee: u256,
    /// Ascending by `min_volume`; the first tier starts at zero.
    volume_tiers: vector<VolumeTier>,
    /// Ascending by `min_stake` and by `discount`.
    staking_tiers: vector<StakingTier>,
    /// How long a cached multiplier stays valid on a market.
    multiplier_ttl_ms: u64,
    /// Epochs of taker volume that count toward a volume tier.
    window_epochs: u64,
}

public struct VolumeTier has copy, drop, store {
    min_volume: u256,
    taker_fee: u256,
    maker_fee: u256,
}

public struct StakingTier has copy, drop, store {
    min_stake: u64,
    discount: u256,
}

public struct AdminCap has key, store { id: UID }

// === Events ===

public struct ScheduleUpdated has copy, drop {
    base_taker_fee: u256,
    base_maker_fee: u256,
    volume_tiers: vector<VolumeTier>,
    staking_tiers: vector<StakingTier>,
    multiplier_ttl_ms: u64,
    window_epochs: u64,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(FeeSchedule {
        id: object::new(ctx),
        version: VERSION,
        base_taker_fee: 0,
        base_maker_fee: 0,
        volume_tiers: vector[],
        staking_tiers: vector[],
        multiplier_ttl_ms: 86_400_000,
        window_epochs: 14,
    });
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Admin ===

/// Replaces the whole schedule. Tier vectors are passed column-wise so the call stays usable
/// from a transaction block.
public fun set_schedule(
    schedule: &mut FeeSchedule,
    _: &AdminCap,
    base_taker_fee: u256,
    base_maker_fee: u256,
    volume_min: vector<u256>,
    volume_taker_fee: vector<u256>,
    volume_maker_fee: vector<u256>,
    staking_min: vector<u64>,
    staking_discount: vector<u256>,
    multiplier_ttl_ms: u64,
    window_epochs: u64,
) {
    schedule.assert_version();
    assert!(!ifixed::is_neg(base_taker_fee) && base_taker_fee != 0, EInvalidBaseFee);
    assert!(!ifixed::is_neg(base_maker_fee), EInvalidBaseFee);
    assert!(
        volume_min.length() == volume_taker_fee.length()
            && volume_min.length() == volume_maker_fee.length()
            && staking_min.length() == staking_discount.length(),
        ELengthMismatch,
    );
    assert!(multiplier_ttl_ms > 0, EInvalidTtl);
    assert!(window_epochs > 0 && window_epochs <= MAX_WINDOW_EPOCHS, EInvalidWindow);

    let mut volume_tiers = vector[];
    let mut i = 0;
    while (i < volume_min.length()) {
        let (min_volume, taker_fee, maker_fee) = (volume_min[i], volume_taker_fee[i], volume_maker_fee[i]);
        if (i == 0) {
            assert!(min_volume == 0, EFirstVolumeTierNotZero);
        } else {
            assert!(ifixed::less_than(volume_min[i - 1], min_volume), EVolumeTiersNotAscending);
        };
        assert!(
            !ifixed::is_neg(taker_fee) && ifixed::less_than_eq(taker_fee, base_taker_fee),
            ETierFeeAboveBase,
        );
        assert!(
            !ifixed::is_neg(maker_fee) && ifixed::less_than_eq(maker_fee, base_maker_fee),
            ETierFeeAboveBase,
        );
        volume_tiers.push_back(VolumeTier { min_volume, taker_fee, maker_fee });
        i = i + 1;
    };

    let mut staking_tiers = vector[];
    let one = ifixed::one();
    i = 0;
    while (i < staking_min.length()) {
        let (min_stake, discount) = (staking_min[i], staking_discount[i]);
        assert!(!ifixed::is_neg(discount) && ifixed::less_than_eq(discount, one), EInvalidDiscount);
        if (i > 0) {
            assert!(staking_min[i - 1] < min_stake, EStakingTiersNotAscending);
            assert!(ifixed::less_than_eq(staking_discount[i - 1], discount), EStakingTiersNotAscending);
        } else {
            // Tier 0 is "no stake, no discount"; the first listed tier must demand a stake.
            assert!(min_stake > 0, EStakingTiersNotAscending);
        };
        staking_tiers.push_back(StakingTier { min_stake, discount });
        i = i + 1;
    };

    schedule.base_taker_fee = base_taker_fee;
    schedule.base_maker_fee = base_maker_fee;
    schedule.volume_tiers = volume_tiers;
    schedule.staking_tiers = staking_tiers;
    schedule.multiplier_ttl_ms = multiplier_ttl_ms;
    schedule.window_epochs = window_epochs;
    event::emit(ScheduleUpdated {
        base_taker_fee,
        base_maker_fee,
        volume_tiers,
        staking_tiers,
        multiplier_ttl_ms,
        window_epochs,
    });
}

entry fun migrate(schedule: &mut FeeSchedule, _: &AdminCap) {
    assert!(schedule.version < VERSION, EWrongVersion);
    schedule.version = VERSION;
}

// === Views ===

/// The (taker, maker) multipliers for an account with `volume` over the window and `stake`
/// deposited. An unconfigured schedule yields no discount.
public fun multipliers(schedule: &FeeSchedule, volume: u256, stake: u64): (u256, u256) {
    let one = ifixed::one();
    if (schedule.volume_tiers.is_empty() || schedule.base_taker_fee == 0) return (one, one);
    let tier = &schedule.volume_tiers[schedule.volume_tier_index(volume)];
    let discount = schedule.staking_discount(stake);
    let keep = ifixed::sub(one, discount);
    let taker = rate_multiplier(ifixed::mul_toward_zero(tier.taker_fee, keep), schedule.base_taker_fee);
    let maker = rate_multiplier(ifixed::mul_toward_zero(tier.maker_fee, keep), schedule.base_maker_fee);
    (taker, maker)
}

/// Index of the highest volume tier `volume` reaches (0 when the schedule is empty).
public fun volume_tier_index(schedule: &FeeSchedule, volume: u256): u64 {
    let mut index = 0;
    let mut i = 1;
    while (i < schedule.volume_tiers.length()) {
        if (ifixed::greater_than_eq(volume, schedule.volume_tiers[i].min_volume)) index = i;
        i = i + 1;
    };
    index
}

/// Number of staking tiers `stake` reaches (0 below the first).
public fun staking_tier_index(schedule: &FeeSchedule, stake: u64): u64 {
    let mut count = 0;
    schedule.staking_tiers.do_ref!(|tier| if (stake >= tier.min_stake) count = count + 1);
    count
}

public fun staking_discount(schedule: &FeeSchedule, stake: u64): u256 {
    let count = schedule.staking_tier_index(stake);
    if (count == 0) 0 else schedule.staking_tiers[count - 1].discount
}

public fun base_taker_fee(schedule: &FeeSchedule): u256 { schedule.base_taker_fee }

public fun base_maker_fee(schedule: &FeeSchedule): u256 { schedule.base_maker_fee }

public fun multiplier_ttl_ms(schedule: &FeeSchedule): u64 { schedule.multiplier_ttl_ms }

public fun window_epochs(schedule: &FeeSchedule): u64 { schedule.window_epochs }

public fun volume_tiers(schedule: &FeeSchedule): &vector<VolumeTier> { &schedule.volume_tiers }

public fun staking_tiers(schedule: &FeeSchedule): &vector<StakingTier> { &schedule.staking_tiers }

public fun volume_tier_fields(tier: &VolumeTier): (u256, u256, u256) {
    (tier.min_volume, tier.taker_fee, tier.maker_fee)
}

public fun staking_tier_fields(tier: &StakingTier): (u64, u256) { (tier.min_stake, tier.discount) }

public(package) fun assert_version(schedule: &FeeSchedule) {
    assert!(schedule.version == VERSION, EWrongVersion)
}

// === Internal ===

/// `rate / base`, capped at one; a zero base means the rate is unused on that side.
fun rate_multiplier(rate: u256, base: u256): u256 {
    let one = ifixed::one();
    if (base == 0) return one;
    ifixed::min(ifixed::div_toward_zero(rate, base), one)
}

// === Test helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
