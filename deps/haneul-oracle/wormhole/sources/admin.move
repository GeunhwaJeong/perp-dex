// SPDX-License-Identifier: Apache 2

/// Local administrative authority for this deployment.
///
/// Upstream gates contract upgrades and fee configuration behind Wormhole
/// governance VAAs targeting the local chain ID. Guardians only sign local
/// actions for chains registered with Wormhole governance, so on this
/// deployment those VAAs can never exist and the upstream paths are
/// unreachable. The `AdminCap`, transferred to the publisher at init, stands
/// in for local governance.
///
/// Guardian set updates are deliberately NOT admin-gated: they are global
/// governance (target chain 0), signed by the guardians themselves, and stay
/// VAA-driven and permissionless exactly as upstream (see
/// `update_guardian_set`).
module wormhole::admin {
    use haneul::coin::{Self};
    use haneul::object::{Self, ID, UID};
    use haneul::package::{UpgradeTicket};
    use haneul::transfer::{Self};
    use haneul::tx_context::{Self, TxContext};

    use wormhole::bytes32::{Self};
    use wormhole::state::{Self, State};

    /// Digest is all zeros.
    const E_DIGEST_ZERO_BYTES: u64 = 0;

    /// Authority over local governance actions: contract upgrades and fee
    /// configuration.
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
    /// ticket, then `upgrade_contract::commit_upgrade` with the receipt.
    public fun authorize_upgrade(
        _: &AdminCap,
        wormhole_state: &mut State,
        package_digest: vector<u8>
    ): UpgradeTicket {
        let digest = bytes32::from_bytes(package_digest);
        assert!(bytes32::is_nonzero(&digest), E_DIGEST_ZERO_BYTES);
        state::authorize_upgrade(wormhole_state, digest)
    }

    /// Roll state access to the new build after an admin-authorized upgrade
    /// has been committed. Replaces `migrate::migrate`, which requires the
    /// upgrade governance VAA to re-derive the digest; the Haneul VM already
    /// guarantees only the latest package can execute this.
    public fun migrate(_: &AdminCap, wormhole_state: &mut State) {
        state::migrate__v__0_2_0(wormhole_state);
        state::migrate_version(wormhole_state);

        let latest_only = state::assert_latest_only(wormhole_state);
        let package = state::current_package(&latest_only, wormhole_state);
        haneul::event::emit(AdminMigrateComplete { package });
    }

    /// Set the fee for publishing a Wormhole message.
    public fun set_fee(
        _: &AdminCap,
        wormhole_state: &mut State,
        amount: u64
    ) {
        let latest_only = state::assert_latest_only(wormhole_state);
        state::set_message_fee(&latest_only, wormhole_state, amount);
    }

    /// Withdraw collected message fees to a recipient.
    public fun transfer_fee(
        _: &AdminCap,
        wormhole_state: &mut State,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let latest_only = state::assert_latest_only(wormhole_state);
        transfer::public_transfer(
            coin::from_balance(
                state::withdraw_fee(&latest_only, wormhole_state, amount),
                ctx
            ),
            recipient
        );
    }

    #[test_only]
    public fun init_test_only(ctx: &mut TxContext) {
        init(ctx);
    }
}

#[test_only]
module wormhole::admin_tests {
    use haneul::coin::{Self, Coin};
    use haneul::haneul::{HANEUL};
    use haneul::test_scenario::{Self};

    use wormhole::admin::{Self, AdminCap};
    use wormhole::state::{Self, State};
    use wormhole::wormhole_scenario::{
        person,
        return_state,
        set_up_wormhole,
        take_state
    };

    #[test]
    fun test_admin_set_fee() {
        let deployer = person();
        let my_scenario = test_scenario::begin(deployer);
        let scenario = &mut my_scenario;

        let wormhole_message_fee = 350;
        set_up_wormhole(scenario, wormhole_message_fee);
        test_scenario::next_tx(scenario, deployer);
        admin::init_test_only(test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, deployer);

        let worm_state = take_state(scenario);
        let cap =
            test_scenario::take_from_address<AdminCap>(scenario, deployer);

        assert!(state::message_fee(&worm_state) == wormhole_message_fee, 0);
        admin::set_fee(&cap, &mut worm_state, 9999);
        assert!(state::message_fee(&worm_state) == 9999, 0);

        test_scenario::return_to_address(deployer, cap);
        return_state(worm_state);
        test_scenario::end(my_scenario);
    }

    #[test]
    fun test_admin_transfer_fee() {
        let deployer = person();
        let my_scenario = test_scenario::begin(deployer);
        let scenario = &mut my_scenario;

        let wormhole_message_fee = 350;
        set_up_wormhole(scenario, wormhole_message_fee);
        test_scenario::next_tx(scenario, deployer);
        admin::init_test_only(test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, deployer);

        let worm_state = take_state(scenario);
        let cap =
            test_scenario::take_from_address<AdminCap>(scenario, deployer);

        // Deposit fees, then withdraw them to the deployer via the admin.
        state::deposit_fee_test_only(
            &mut worm_state,
            coin::into_balance(
                coin::mint_for_testing<HANEUL>(
                    wormhole_message_fee,
                    test_scenario::ctx(scenario)
                )
            )
        );
        admin::transfer_fee(
            &cap,
            &mut worm_state,
            wormhole_message_fee,
            deployer,
            test_scenario::ctx(scenario)
        );
        test_scenario::next_tx(scenario, deployer);

        let withdrawn =
            test_scenario::take_from_address<Coin<HANEUL>>(
                scenario,
                deployer
            );
        assert!(coin::value(&withdrawn) == wormhole_message_fee, 0);

        coin::burn_for_testing(withdrawn);
        test_scenario::return_to_address(deployer, cap);
        return_state(worm_state);
        test_scenario::end(my_scenario);
    }

    #[test]
    fun test_admin_migrate() {
        let deployer = person();
        let my_scenario = test_scenario::begin(deployer);
        let scenario = &mut my_scenario;

        set_up_wormhole(scenario, 350);
        test_scenario::next_tx(scenario, deployer);
        admin::init_test_only(test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, deployer);

        // Simulate an upgraded package whose state still points at the
        // previous version, then roll it forward via the admin.
        wormhole::wormhole_scenario::upgrade_wormhole(scenario);
        test_scenario::next_tx(scenario, deployer);

        let worm_state = take_state(scenario);
        let cap =
            test_scenario::take_from_address<AdminCap>(scenario, deployer);

        wormhole::migrate::set_up_migrate(&mut worm_state);
        state::reverse_migrate_version(&mut worm_state);
        admin::migrate(&cap, &mut worm_state);

        test_scenario::return_to_address(deployer, cap);
        return_state(worm_state);
        test_scenario::end(my_scenario);
    }
}
