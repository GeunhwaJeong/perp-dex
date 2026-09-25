// SPDX-License-Identifier: Apache 2

/// Local administrative authority for this deployment.
///
/// Upstream gates contract upgrades and configuration changes behind Pyth
/// governance VAAs targeting the local Wormhole chain ID. Pyth governance
/// only emits VAAs for chains it officially supports, so on this deployment
/// those paths can never be exercised. The `AdminCap`, transferred to the
/// publisher at init, stands in for that governance.
///
/// Price feed updates are untouched: they stay VAA-verified and
/// permissionless exactly as upstream.
module pyth::admin {
    use std::vector::{Self};
    use haneul::object::{Self, ID, UID};
    use haneul::package::{UpgradeTicket};
    use haneul::transfer::{Self};
    use haneul::tx_context::{Self, TxContext};

    use wormhole::bytes32::{Self};
    use wormhole::external_address::{Self};

    use pyth::data_source::{Self, DataSource};
    use pyth::state::{Self, State};

    /// Digest is all zeros.
    const E_DIGEST_ZERO_BYTES: u64 = 0;
    /// Emitter chain and emitter address vectors differ in length.
    const E_DATA_SOURCE_ARITY: u64 = 1;

    /// Authority over local governance actions: contract upgrades, fee and
    /// staleness configuration, and the accepted data sources.
    struct AdminCap has key, store {
        id: UID
    }

    /// Event reflecting a completed admin migration.
    struct AdminMigrateComplete has drop, copy {
        package: ID
    }

    /// Transfers `AdminCap` to the publisher.
    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap { id: object::new(ctx) },
            tx_context::sender(ctx)
        );
    }

    /// Issue an `UpgradeTicket` for the build with the given digest,
    /// authorized by the admin in place of an upgrade governance VAA. The
    /// rest of the upgrade flow is unchanged: run the upgrade with the
    /// ticket, then `contract_upgrade::commit_upgrade` with the receipt.
    public fun authorize_upgrade(
        _: &AdminCap,
        pyth_state: &mut State,
        package_digest: vector<u8>
    ): UpgradeTicket {
        let digest = bytes32::from_bytes(package_digest);
        assert!(bytes32::is_nonzero(&digest), E_DIGEST_ZERO_BYTES);
        state::authorize_upgrade(pyth_state, digest)
    }

    /// Roll state access to the new build after an admin-authorized upgrade
    /// has been committed. Replaces `migrate::migrate`, which requires the
    /// upgrade governance VAA to re-derive the digest; the Haneul VM already
    /// guarantees only the latest package can execute this.
    public fun migrate(_: &AdminCap, pyth_state: &mut State) {
        state::migrate_version(pyth_state);

        let latest_only = state::assert_latest_only(pyth_state);
        let package = state::current_package(&latest_only, pyth_state);
        haneul::event::emit(AdminMigrateComplete { package });
    }

    /// Set the base fee for submitting a price update.
    public fun set_update_fee(
        _: &AdminCap,
        pyth_state: &mut State,
        fee: u64
    ) {
        let latest_only = state::assert_latest_only(pyth_state);
        state::set_base_update_fee(&latest_only, pyth_state, fee);
    }

    /// Set the default staleness threshold (seconds) for price reads.
    public fun set_stale_price_threshold(
        _: &AdminCap,
        pyth_state: &mut State,
        threshold_secs: u64
    ) {
        let latest_only = state::assert_latest_only(pyth_state);
        state::set_stale_price_threshold_secs(
            &latest_only,
            pyth_state,
            threshold_secs
        );
    }

    /// Set the recipient of collected update fees.
    public fun set_fee_recipient(
        _: &AdminCap,
        pyth_state: &mut State,
        recipient: address
    ) {
        let latest_only = state::assert_latest_only(pyth_state);
        state::set_fee_recipient(&latest_only, pyth_state, recipient);
    }

    /// Replace the set of accepted price update data sources. Takes parallel
    /// vectors of Wormhole emitter chain IDs and 32-byte emitter addresses.
    public fun set_data_sources(
        _: &AdminCap,
        pyth_state: &mut State,
        emitter_chains: vector<u64>,
        emitter_addresses: vector<vector<u8>>
    ) {
        let n = vector::length(&emitter_chains);
        assert!(
            n == vector::length(&emitter_addresses),
            E_DATA_SOURCE_ARITY
        );

        let sources = vector::empty<DataSource>();
        let i = 0;
        while (i < n) {
            vector::push_back(
                &mut sources,
                data_source::new(
                    *vector::borrow(&emitter_chains, i),
                    external_address::new(
                        bytes32::from_bytes(
                            *vector::borrow(&emitter_addresses, i)
                        )
                    )
                )
            );
            i = i + 1;
        };

        let latest_only = state::assert_latest_only(pyth_state);
        state::set_data_sources(&latest_only, pyth_state, sources);
    }

    /// Replace the governance data source. Kept for completeness even though
    /// this deployment's governance actions flow through the admin.
    public fun set_governance_data_source(
        _: &AdminCap,
        pyth_state: &mut State,
        emitter_chain: u64,
        emitter_address: vector<u8>
    ) {
        let latest_only = state::assert_latest_only(pyth_state);
        state::set_governance_data_source(
            &latest_only,
            pyth_state,
            data_source::new(
                emitter_chain,
                external_address::new(
                    bytes32::from_bytes(emitter_address)
                )
            )
        );
    }

    #[test_only]
    public fun init_test_only(ctx: &mut TxContext) {
        init(ctx);
    }
}

#[test_only]
module pyth::admin_tests {
    use haneul::test_scenario::{Self};

    use pyth::admin::{Self, AdminCap};
    use pyth::data_source::{Self};
    use pyth::pyth_tests::{Self, setup_test, take_wormhole_and_pyth_states};
    use pyth::state::{Self};

    use wormhole::bytes32::{Self};
    use wormhole::external_address::{Self};

    const DEPLOYER: address = @0x1234;

    fun setup(): (
        haneul::test_scenario::Scenario,
        haneul::coin::Coin<haneul::haneul::HANEUL>,
        haneul::clock::Clock
    ) {
        setup_test(
            500,
            1,
            x"63278d271099bfd491951b3e648f08b1c71631e4a53674ad43e8f9f98068c385",
            pyth_tests::data_sources_for_test_vaa(),
            vector[x"befa429d57cd18b7f8a4d91a2da9ab4af05d0fbe"],
            50,
            0
        )
    }

    #[test]
    fun test_admin_set_update_fee_and_threshold() {
        let (scenario, test_coins, clock) = setup();
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        admin::init_test_only(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, DEPLOYER);

        let (pyth_state, worm_state) =
            take_wormhole_and_pyth_states(&scenario);
        let cap =
            test_scenario::take_from_address<AdminCap>(&scenario, DEPLOYER);

        admin::set_update_fee(&cap, &mut pyth_state, 777);
        assert!(state::get_base_update_fee(&pyth_state) == 777, 0);

        admin::set_stale_price_threshold(&cap, &mut pyth_state, 120);
        assert!(
            state::get_stale_price_threshold_secs(&pyth_state) == 120,
            0
        );

        test_scenario::return_to_address(DEPLOYER, cap);
        haneul::coin::burn_for_testing(test_coins);
        pyth_tests::cleanup_worm_state_pyth_state_and_clock(
            worm_state,
            pyth_state,
            clock
        );
        test_scenario::end(scenario);
    }

    #[test]
    fun test_admin_set_data_sources() {
        let (scenario, test_coins, clock) = setup();
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        admin::init_test_only(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, DEPLOYER);

        let (pyth_state, worm_state) =
            take_wormhole_and_pyth_states(&scenario);
        let cap =
            test_scenario::take_from_address<AdminCap>(&scenario, DEPLOYER);

        let emitter =
            x"f346195ac02f37d60d4db8ffa6ef74cb1be3550047543a4a9ee9acf4d78697b0";
        admin::set_data_sources(
            &cap,
            &mut pyth_state,
            vector[1],
            vector[emitter]
        );
        assert!(
            state::is_valid_data_source(
                &pyth_state,
                data_source::new_data_source_for_test(
                    1,
                    external_address::new(bytes32::from_bytes(emitter))
                )
            ),
            0
        );

        test_scenario::return_to_address(DEPLOYER, cap);
        haneul::coin::burn_for_testing(test_coins);
        pyth_tests::cleanup_worm_state_pyth_state_and_clock(
            worm_state,
            pyth_state,
            clock
        );
        test_scenario::end(scenario);
    }
}
