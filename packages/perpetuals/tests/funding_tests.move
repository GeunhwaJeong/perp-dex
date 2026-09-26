// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Funding on the `test_support` fixture: the premium cap and the funding it bounds.
#[test_only]
module perpetuals::funding_tests;

use ifixed::ifixed;
use perpetuals::test_support::{Self as t, session, with_market};

const ASK: bool = true;
const BID: bool = false;

/// The maker rests the book well above the index: asks at 103,000 and bids at 102,000, a mid of
/// 102,500 against an index of 100,000 (a 2.5% premium, inside the 5% spread clip).
fun lean_book_above_index(sc: &mut haneul::test_scenario::Scenario, fx: &t::Fx) {
    session!(sc, fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(103_000), 0, option::none(), false, option::none());
        hp.place_limit_order(BID, t::mbtc(100), t::px(102_000), 0, option::none(), false, option::none());
    });
}

/// Advances a minute at the same index price and samples the TWAPs.
fun sample_after_a_minute(sc: &mut haneul::test_scenario::Scenario, fx: &mut t::Fx) {
    t::set_price(sc, fx, 100_000, 60_000);
    with_market!(sc, fx, t::maker(), |ch, _account, btc, _tusd, _registry| {
        ch.update_twaps(btc, fx.clock());
    });
}

#[test]
fun the_premium_is_capped_at_the_max_funding_rate() {
    let (mut sc, mut fx) = t::setup();
    lean_book_above_index(&mut sc, &fx);
    // A full TWAP window later the premium TWAP has converged on the capped sample: 0.5% of
    // 100,000 is 500, not the book's 2,500.
    sample_after_a_minute(&mut sc, &mut fx);
    sample_after_a_minute(&mut sc, &mut fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, _tusd, _registry| {
        assert!(ch.market_params().max_funding_rate() == 5_000_000_000_000_000);
        let premium = ch.market_state().premium_twap();
        assert!(ifixed::less_than_eq(premium, t::usd(500)) && ifixed::greater_than(premium, t::usd(499)));
        // The two funding intervals elapsed (two minutes of a six hour period) charge at most
        // 500 * 2 / 360 per unit of base.
        ch.update_funding(btc, fx.clock());
        let (long_rate, short_rate) = ch.market_state().cum_funding_rates();
        assert!(long_rate == short_rate);
        assert!(ifixed::greater_than(long_rate, 0));
        assert!(ifixed::less_than_eq(long_rate, t::usd(500) * 2 / 360));
    });
    // Raising the cap to 5% lets the same book move the TWAP toward its real 2,500 premium.
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(), option::some(ifixed::from_u64fraction(5, 100)),
        );
    });
    sample_after_a_minute(&mut sc, &mut fx);
    sample_after_a_minute(&mut sc, &mut fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, _registry| {
        let premium = ch.market_state().premium_twap();
        assert!(ifixed::greater_than(premium, t::usd(2_400)) && ifixed::less_than_eq(premium, t::usd(2_500)));
    });
    t::finish(sc, fx);
}

#[test]
fun missed_intervals_are_caught_up_three_at_a_time() {
    let (mut sc, mut fx) = t::setup();
    lean_book_above_index(&mut sc, &fx);
    sample_after_a_minute(&mut sc, &mut fx);
    sample_after_a_minute(&mut sc, &mut fx);
    // Ten funding intervals pass without a crank.
    t::set_price(&mut sc, &mut fx, 100_000, 600_000);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, _tusd, _registry| {
        let last_update = ch.market_state().funding_last_upd_ms();
        ch.update_funding(btc, fx.clock());
        let now = fx.clock().timestamp_ms();
        assert!(ch.market_state().funding_last_upd_ms() == now);
        // Only three of the twelve elapsed intervals are charged, at the premium TWAP the
        // update sampled.
        let premium = ch.market_state().premium_twap();
        let (long_rate, _) = ch.market_state().cum_funding_rates();
        let three_intervals = perpetuals::market::funding_period_adjustment(now, last_update, 60_000, 21_600_000);
        assert!(three_intervals == ifixed::from_u64fraction(3 * 60_000, 21_600_000));
        assert!(long_rate == ifixed::mul(premium, three_intervals));
        assert!(ifixed::less_than(long_rate, ifixed::mul(premium, ifixed::from_u64fraction(12 * 60_000, 21_600_000))));
    });
    t::finish(sc, fx);
}

#[test]
fun the_cap_binds_a_book_below_the_index_as_well() {
    let (mut sc, mut fx) = t::setup();
    // Mid 97,500: a -2.5% premium, capped at -500.
    session!(&mut sc, &fx, t::maker(), false, false, |hp| {
        hp.place_limit_order(ASK, t::mbtc(100), t::px(98_000), 0, option::none(), false, option::none());
        hp.place_limit_order(BID, t::mbtc(100), t::px(97_000), 0, option::none(), false, option::none());
    });
    sample_after_a_minute(&mut sc, &mut fx);
    sample_after_a_minute(&mut sc, &mut fx);
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, btc, _tusd, _registry| {
        let premium = ch.market_state().premium_twap();
        assert!(ifixed::is_neg(premium));
        assert!(ifixed::less_than_eq(ifixed::abs(premium), t::usd(500)));
        assert!(ifixed::greater_than(ifixed::abs(premium), t::usd(499)));
        ch.update_funding(btc, fx.clock());
        let (long_rate, _) = ch.market_state().cum_funding_rates();
        assert!(ifixed::is_neg(long_rate));
        assert!(ifixed::less_than_eq(ifixed::abs(long_rate), t::usd(500) * 2 / 360));
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 1029, location = perpetuals::market)]
fun a_zero_max_funding_rate_is_refused() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(), option::some(0),
        );
    });
    t::finish(sc, fx);
}

#[test, expected_failure(abort_code = 1029, location = perpetuals::market)]
fun a_max_funding_rate_above_one_is_refused() {
    let (mut sc, fx) = t::setup();
    with_market!(&mut sc, &fx, t::maker(), |ch, _account, _btc, _tusd, registry| {
        ch.set_risk_limit_params(
            t::perp_vk(&fx), registry, option::none(), option::none(), option::none(),
            option::none(), option::none(), option::none(), option::none(), option::none(),
            option::none(), option::some(t::one() + 1),
        );
    });
    t::finish(sc, fx);
}
