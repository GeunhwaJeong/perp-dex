module pyth::set_stale_price_threshold {
    use wormhole::cursor;

    use pyth::deserialize;
    use pyth::state::{Self, State, LatestOnly};

    friend pyth::governance;

    struct StalePriceThreshold {
        threshold: u64,
    }

    public(friend) fun execute(latest_only: &LatestOnly, state: &mut State, payload: vector<u8>) {
        let StalePriceThreshold { threshold } = from_byte_vec(payload);
        state::set_stale_price_threshold_secs(latest_only, state, threshold);
    }

    fun from_byte_vec(bytes: vector<u8>): StalePriceThreshold {
        let cursor = cursor::new(bytes);
        let threshold = deserialize::deserialize_u64(&mut cursor);
        cursor::destroy_empty(cursor);
        StalePriceThreshold {
            threshold
        }
    }
}

#[test_only]
module pyth::set_stale_price_threshold_test {
    use haneul::test_scenario::{Self};
    use haneul::coin::Self;

    use pyth::pyth_tests::{Self, setup_test, take_wormhole_and_pyth_states};
    use pyth::state::Self;

    const SET_STALE_PRICE_THRESHOLD_VAA: vector<u8> = x"010000000001007c7e2220369c83cbc961ba1c2173a3fa589961946184d2a16989af375da74b493424e36a5b4f3e8711a26db01156e16bf1329071103125c8261fe62deb0296fa010000000000000000000163278d271099bfd491951b3e648f08b1c71631e4a53674ad43e8f9f98068c3850000000000000001015054474d0104205a00000000000f4020";
    // VAA Info:
    //   module name: 0x1
    //   action: 4
    //   chain: 21
    //   stale price threshold: 999456

    const DEPLOYER: address = @0x1234;
    const DEFAULT_BASE_UPDATE_FEE: u64 = 0;
    const DEFAULT_COIN_TO_MINT: u64 = 0;

    #[test]
    fun set_stale_price_threshold(){

        let (scenario, test_coins, clock) =  setup_test(500, 1, x"63278d271099bfd491951b3e648f08b1c71631e4a53674ad43e8f9f98068c385", pyth_tests::data_sources_for_test_vaa(), vector[x"befa429d57cd18b7f8a4d91a2da9ab4af05d0fbe"], DEFAULT_BASE_UPDATE_FEE, DEFAULT_COIN_TO_MINT);
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        let (pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

        let verified_vaa = wormhole::vaa::parse_and_verify(&worm_state, SET_STALE_PRICE_THRESHOLD_VAA, &clock);

        let receipt = pyth::governance::verify_vaa(&pyth_state, verified_vaa);

        test_scenario::next_tx(&mut scenario, DEPLOYER);

        pyth::governance::execute_governance_instruction(&mut pyth_state, receipt);

        test_scenario::next_tx(&mut scenario, DEPLOYER);

        // assert stale price threshold is set correctly
        assert!(state::get_stale_price_threshold_secs(&pyth_state)==999456, 0);

        // clean up
        coin::burn_for_testing(test_coins);
        pyth_tests::cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
        test_scenario::end(scenario);
    }
}
