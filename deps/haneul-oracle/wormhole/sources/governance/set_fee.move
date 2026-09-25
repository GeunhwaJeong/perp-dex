// SPDX-License-Identifier: Apache 2

/// This module implements handling a governance VAA to enact setting the
/// Wormhole message fee to another amount.
module wormhole::set_fee {
    use wormhole::bytes32::{Self};
    use wormhole::cursor::{Self};
    use wormhole::governance_message::{Self, DecreeTicket, DecreeReceipt};
    use wormhole::state::{Self, State};

    /// Specific governance payload ID (action) for setting Wormhole fee.
    const ACTION_SET_FEE: u8 = 3;

    struct GovernanceWitness has drop {}

    struct SetFee {
        amount: u64
    }

    public fun authorize_governance(
        wormhole_state: &State
    ): DecreeTicket<GovernanceWitness> {
        governance_message::authorize_verify_local(
            GovernanceWitness {},
            state::governance_chain(wormhole_state),
            state::governance_contract(wormhole_state),
            state::governance_module(),
            ACTION_SET_FEE
        )
    }

    /// Redeem governance VAA to configure Wormhole message fee amount in HANEUL
    /// denomination. This governance message is only relevant for Haneul because
    /// fee administration is only relevant to one particular network (in this
    /// case Haneul).
    ///
    /// NOTE: This method is guarded by a minimum build version check. This
    /// method could break backward compatibility on an upgrade.
    public fun set_fee(
        wormhole_state: &mut State,
        receipt: DecreeReceipt<GovernanceWitness>
    ): u64 {
        // This capability ensures that the current build version is used.
        let latest_only = state::assert_latest_only(wormhole_state);

        let payload =
            governance_message::take_payload(
                state::borrow_mut_consumed_vaas(&latest_only, wormhole_state),
                receipt
            );

        // Deserialize the payload as amount to change the Wormhole fee.
        let SetFee { amount } = deserialize(payload);

        state::set_message_fee(&latest_only, wormhole_state, amount);

        amount
    }

    fun deserialize(payload: vector<u8>): SetFee {
        let cur = cursor::new(payload);

        // This amount cannot be greater than max u64.
        let amount = bytes32::to_u64_be(bytes32::take_bytes(&mut cur));

        cursor::destroy_empty(cur);

        SetFee { amount: (amount as u64) }
    }

    #[test_only]
    public fun action(): u8 {
        ACTION_SET_FEE
    }
}

#[test_only]
module wormhole::set_fee_tests {
    use haneul::balance::{Self};
    use haneul::test_scenario::{Self};

    use wormhole::bytes::{Self};
    use wormhole::cursor::{Self};
    use wormhole::governance_message::{Self};
    use wormhole::set_fee::{Self};
    use wormhole::state::{Self};
    use wormhole::vaa::{Self};
    use wormhole::version_control::{Self};
    use wormhole::wormhole_scenario::{
        person,
        return_clock,
        return_state,
        set_up_wormhole,
        take_clock,
        take_state,
        upgrade_wormhole
    };

    const VAA_SET_FEE_1: vector<u8> =
        x"010000000001008d5b47735ab8d5cd1a7332534e85e775116953d33a6751dca2202d949d69c4983b8bf7a1d420711ce280f37f3335e1a5d4df579ab6d8c6cecdf0b7d7e905bb840000bc614e000000000001000000000000000000000000000000000000000000000000000000000000000400000000000000010100000000000000000000000000000000000000000000000000000000436f726503205a000000000000000000000000000000000000000000000000000000000000015e";
    const VAA_SET_FEE_MAX: vector<u8> =
        x"010000000001007aa69ec92320420122ec0190c4352998a9bde9b907f44721550de9c1bea99eef4663293194c050b194b0167e28b417f84239cad239b5d542f533b971c7f360570100bc614e000000000001000000000000000000000000000000000000000000000000000000000000000400000000000000010100000000000000000000000000000000000000000000000000000000436f726503205a000000000000000000000000000000000000000000000000ffffffffffffffff";
    const VAA_SET_FEE_OVERFLOW: vector<u8> =
        x"010000000001008003fc9d0c75b9ebdbcc957b2d565cedf52bd12b88d75368b719c18e2361831e7157ea15493af315851b2fa159dfba2d286c567802a7669e4e002d5387085ddc0100bc614e000000000001000000000000000000000000000000000000000000000000000000000000000400000000000000010100000000000000000000000000000000000000000000000000000000436f726503205a0000000000000000000000000000000000000000000000010000000000000000";

    #[test]
    fun test_set_fee() {
        // Testing this method.
        use wormhole::set_fee::{set_fee};

        // Set up.
        let caller = person();
        let my_scenario = test_scenario::begin(caller);
        let scenario = &mut my_scenario;

        let wormhole_fee = 420;
        set_up_wormhole(scenario, wormhole_fee);

        // Prepare test to execute `set_fee`.
        test_scenario::next_tx(scenario, caller);

        let worm_state = take_state(scenario);
        let the_clock = take_clock(scenario);

        // Double-check current fee (from setup).
        assert!(state::message_fee(&worm_state) == wormhole_fee, 0);

        let verified_vaa =
            vaa::parse_and_verify(&worm_state, VAA_SET_FEE_1, &the_clock);
        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);
        let fee_amount = set_fee(&mut worm_state, receipt);
        assert!(wormhole_fee != fee_amount, 0);

        // Confirm the fee changed.
        assert!(state::message_fee(&worm_state) == fee_amount, 0);

        // And confirm that we can deposit the new fee amount.
        state::deposit_fee_test_only(
            &mut worm_state,
            balance::create_for_testing(fee_amount)
        );

        // Finally set the fee again to max u64 (this will effectively pause
        // Wormhole message publishing until the fee gets adjusted back to a
        // reasonable level again).
        let verified_vaa =
            vaa::parse_and_verify(&worm_state, VAA_SET_FEE_MAX, &the_clock);
        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);
        let fee_amount = set_fee(&mut worm_state, receipt);

        // Confirm.
        assert!(state::message_fee(&worm_state) == fee_amount, 0);

        // Clean up.
        return_state(worm_state);
        return_clock(the_clock);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    fun test_set_fee_after_upgrade() {
        // Testing this method.
        use wormhole::set_fee::{set_fee};

        // Set up.
        let caller = person();
        let my_scenario = test_scenario::begin(caller);
        let scenario = &mut my_scenario;

        let wormhole_fee = 420;
        set_up_wormhole(scenario, wormhole_fee);

        // Upgrade.
        upgrade_wormhole(scenario);

        // Prepare test to execute `set_fee`.
        test_scenario::next_tx(scenario, caller);

        let worm_state = take_state(scenario);
        let the_clock = take_clock(scenario);

        // Double-check current fee (from setup).
        assert!(state::message_fee(&worm_state) == wormhole_fee, 0);

        let verified_vaa =
            vaa::parse_and_verify(&worm_state, VAA_SET_FEE_1, &the_clock);
        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);
        let fee_amount = set_fee(&mut worm_state, receipt);

        // Confirm the fee changed.
        assert!(state::message_fee(&worm_state) == fee_amount, 0);

        // Clean up.
        return_state(worm_state);
        return_clock(the_clock);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    #[expected_failure(abort_code = wormhole::set::E_KEY_ALREADY_EXISTS)]
    fun test_cannot_set_fee_with_same_vaa() {
        // Testing this method.
        use wormhole::set_fee::{set_fee};

        // Set up.
        let caller = person();
        let my_scenario = test_scenario::begin(caller);
        let scenario = &mut my_scenario;

        let wormhole_fee = 420;
        set_up_wormhole(scenario, wormhole_fee);

        // Prepare test to execute `set_fee`.
        test_scenario::next_tx(scenario, caller);

        let worm_state = take_state(scenario);
        let the_clock = take_clock(scenario);

        // Set once.
        let verified_vaa =
            vaa::parse_and_verify(&worm_state, VAA_SET_FEE_1, &the_clock);
        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);
        set_fee(&mut worm_state, receipt);

        let verified_vaa =
            vaa::parse_and_verify(&worm_state, VAA_SET_FEE_1, &the_clock);
        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);

        // You shall not pass!
        set_fee(&mut worm_state, receipt);

        abort 42
    }

    #[test]
    #[expected_failure(abort_code = wormhole::bytes32::E_U64_OVERFLOW)]
    fun test_cannot_set_fee_with_overflow() {
        // Testing this method.
        use wormhole::set_fee::{set_fee};

        // Set up.
        let caller = person();
        let my_scenario = test_scenario::begin(caller);
        let scenario = &mut my_scenario;

        let wormhole_fee = 420;
        set_up_wormhole(scenario, wormhole_fee);

        // Prepare test to execute `set_fee`.
        test_scenario::next_tx(scenario, caller);

        let worm_state = take_state(scenario);
        let the_clock = take_clock(scenario);

        // Show that the encoded fee is greater than u64 max.
        let verified_vaa =
            vaa::parse_and_verify(
                &worm_state,
                VAA_SET_FEE_OVERFLOW,
                &the_clock
            );
        let payload =
            governance_message::take_decree(vaa::payload(&verified_vaa));
        let cur = cursor::new(payload);

        let fee_amount = bytes::take_u256_be(&mut cur);
        assert!(fee_amount > 0xffffffffffffffff, 0);

        cursor::destroy_empty(cur);

        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);

        // You shall not pass!
        set_fee(&mut worm_state, receipt);

        abort 42
    }

    #[test]
    #[expected_failure(abort_code = wormhole::package_utils::E_NOT_CURRENT_VERSION)]
    fun test_cannot_set_fee_outdated_version() {
        // Testing this method.
        use wormhole::set_fee::{set_fee};

        // Set up.
        let caller = person();
        let my_scenario = test_scenario::begin(caller);
        let scenario = &mut my_scenario;

        let wormhole_fee = 420;
        set_up_wormhole(scenario, wormhole_fee);

        // Prepare test to execute `set_fee`.
        test_scenario::next_tx(scenario, caller);

        let worm_state = take_state(scenario);
        let the_clock = take_clock(scenario);

        // Conveniently roll version back.
        state::reverse_migrate_version(&mut worm_state);

        // Simulate executing with an outdated build by upticking the minimum
        // required version for `publish_message` to something greater than
        // this build.
        state::migrate_version_test_only(
            &mut worm_state,
            version_control::previous_version_test_only(),
            version_control::next_version()
        );

        let verified_vaa =
            vaa::parse_and_verify(
                &worm_state,
                VAA_SET_FEE_1,
                &the_clock
            );

        let ticket = set_fee::authorize_governance(&worm_state);
        let receipt =
            governance_message::verify_vaa(&worm_state, verified_vaa, ticket);

        // You shall not pass!
        set_fee(&mut worm_state, receipt);

        abort 42
    }
}
