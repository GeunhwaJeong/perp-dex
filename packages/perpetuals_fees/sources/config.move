// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The fee schedule: volume tiers give absolute taker and maker rates, staking tiers give a
/// discount on top, and maker-share tiers turn the maker rate into a rebate for makers who
/// provide a large share of a market's maker volume. The three combine into the multipliers the
/// perpetuals core applies to a market's own rates. Rates are ifixed fractions of notional
/// (0.045% is 0.00045 ifixed).
///
/// The schedule is written against reference base rates. A tier's multiplier is its rate over
/// the base rate, so a market that charges the base rates pays exactly the schedule; a market
/// with other rates is scaled in proportion. Every tier rate must be at or below the base rate,
/// which keeps the taker multiplier in [0, 1] and the maker multiplier in [-1, 1]: this package
/// can only ever discount or rebate. A rebate must stay below the smallest taker rate any
/// account can reach, since the core pays it out of the taker fee on the same fill.
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
const EShareTiersNotAscending: u64 = 11;
const ERebateAboveTakerFee: u64 = 12;

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
    /// Ascending by `min_share`, non-increasing by `maker_fee` (a negative fee is a rebate).
    share_tiers: vector<ShareTier>,
    /// How long a cached multiplier stays valid on a market.
    multiplier_ttl_ms: u64,
    /// Epochs of volume that count toward a volume tier or a maker share.
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

public struct ShareTier has copy, drop, store {
    /// Ifixed fraction of a market's maker volume over the window.
    min_share: u256,
    maker_fee: u256,
}

public struct AdminCap has key, store { id: UID }

// === Events ===

public struct ScheduleUpdated has copy, drop {
    base_taker_fee: u256,
    base_maker_fee: u256,
    volume_tiers: vector<VolumeTier>,
    staking_tiers: vector<StakingTier>,
    share_tiers: vector<ShareTier>,
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
        share_tiers: vector[],
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
    share_min: vector<u256>,
    share_maker_fee: vector<u256>,
    multiplier_ttl_ms: u64,
    window_epochs: u64,
) {
    schedule.assert_version();
    assert!(!ifixed::is_neg(base_taker_fee) && base_taker_fee != 0, EInvalidBaseFee);
    assert!(!ifixed::is_neg(base_maker_fee), EInvalidBaseFee);
    assert!(
        volume_min.length() == volume_taker_fee.length()
            && volume_min.length() == volume_maker_fee.length()
            && staking_min.length() == staking_discount.length()
            && share_min.length() == share_maker_fee.length(),
        ELengthMismatch,
    );
    assert!(multiplier_ttl_ms > 0, EInvalidTtl);
    assert!(window_epochs > 0 && window_epochs <= MAX_WINDOW_EPOCHS, EInvalidWindow);
    let one = ifixed::one();

    let mut volume_tiers = vector[];
    let mut min_taker_fee = base_taker_fee;
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
        min_taker_fee = ifixed::min(min_taker_fee, taker_fee);
        volume_tiers.push_back(VolumeTier { min_volume, taker_fee, maker_fee });
        i = i + 1;
    };

    let mut staking_tiers = vector[];
    let mut max_discount = 0;
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
        max_discount = ifixed::max(max_discount, discount);
        staking_tiers.push_back(StakingTier { min_stake, discount });
        i = i + 1;
    };

    // The smallest taker rate any account can pay bounds the largest rebate any maker can get.
    let min_effective_taker_fee = ifixed::mul_toward_zero(min_taker_fee, ifixed::sub(one, max_discount));
    let mut share_tiers = vector[];
    i = 0;
    while (i < share_min.length()) {
        let (min_share, maker_fee) = (share_min[i], share_maker_fee[i]);
        assert!(!ifixed::is_neg(min_share) && min_share != 0 && ifixed::less_than_eq(min_share, one), EShareTiersNotAscending);
        if (i > 0) {
            assert!(ifixed::less_than(share_min[i - 1], min_share), EShareTiersNotAscending);
            assert!(ifixed::less_than_eq(maker_fee, share_maker_fee[i - 1]), EShareTiersNotAscending);
        };
        assert!(ifixed::less_than_eq(maker_fee, base_maker_fee), ETierFeeAboveBase);
        assert!(ifixed::less_than_eq(ifixed::abs(maker_fee), min_effective_taker_fee), ERebateAboveTakerFee);
        assert!(ifixed::less_than_eq(ifixed::abs(maker_fee), base_maker_fee) || base_maker_fee == 0, ETierFeeAboveBase);
        share_tiers.push_back(ShareTier { min_share, maker_fee });
        i = i + 1;
    };

    schedule.base_taker_fee = base_taker_fee;
    schedule.base_maker_fee = base_maker_fee;
    schedule.volume_tiers = volume_tiers;
    schedule.staking_tiers = staking_tiers;
    schedule.share_tiers = share_tiers;
    schedule.multiplier_ttl_ms = multiplier_ttl_ms;
    schedule.window_epochs = window_epochs;
    event::emit(ScheduleUpdated {
        base_taker_fee,
        base_maker_fee,
        volume_tiers,
        staking_tiers,
        share_tiers,
        multiplier_ttl_ms,
        window_epochs,
    });
}

entry fun migrate(schedule: &mut FeeSchedule, _: &AdminCap) {
    assert!(schedule.version < VERSION, EWrongVersion);
    schedule.version = VERSION;
}

// === Views ===

/// The (taker, maker) multipliers for an account with `volume` over the window, `stake`
/// deposited and `share` of the market's maker volume. An unconfigured schedule yields the
/// market rates. The staking discount applies to fees paid, never to a rebate.
public fun multipliers(schedule: &FeeSchedule, volume: u256, stake: u64, share: u256): (u256, u256) {
    let one = ifixed::one();
    if (schedule.volume_tiers.is_empty() || schedule.base_taker_fee == 0) return (one, one);
    let tier = &schedule.volume_tiers[schedule.volume_tier_index(volume)];
    let discount = schedule.staking_discount(stake);
    let keep = ifixed::sub(one, discount);
    let taker = rate_multiplier(ifixed::mul_toward_zero(tier.taker_fee, keep), schedule.base_taker_fee);
    let share_count = schedule.share_tier_index(share);
    let maker_rate = if (share_count > 0) {
        let share_fee = schedule.share_tiers[share_count - 1].maker_fee;
        if (ifixed::is_neg(share_fee)) share_fee else ifixed::mul_toward_zero(ifixed::min(share_fee, tier.maker_fee), keep)
    } else {
        ifixed::mul_toward_zero(tier.maker_fee, keep)
    };
    (taker, rate_multiplier(maker_rate, schedule.base_maker_fee))
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

/// Number of share tiers `share` reaches (0 below the first).
public fun share_tier_index(schedule: &FeeSchedule, share: u256): u64 {
    let mut count = 0;
    schedule.share_tiers.do_ref!(|tier| if (ifixed::greater_than_eq(share, tier.min_share)) count = count + 1);
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

public fun share_tiers(schedule: &FeeSchedule): &vector<ShareTier> { &schedule.share_tiers }

public fun volume_tier_fields(tier: &VolumeTier): (u256, u256, u256) {
    (tier.min_volume, tier.taker_fee, tier.maker_fee)
}

public fun staking_tier_fields(tier: &StakingTier): (u64, u256) { (tier.min_stake, tier.discount) }

public fun share_tier_fields(tier: &ShareTier): (u256, u256) { (tier.min_share, tier.maker_fee) }

public(package) fun assert_version(schedule: &FeeSchedule) {
    assert!(schedule.version == VERSION, EWrongVersion)
}

// === Internal ===

/// `rate / base`, capped to [-1, 1]; a zero base means the rate is unused on that side.
fun rate_multiplier(rate: u256, base: u256): u256 {
    let one = ifixed::one();
    if (base == 0) return one;
    ifixed::max(ifixed::min(ifixed::div_toward_zero(rate, base), one), ifixed::neg(one))
}

// === Test helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
