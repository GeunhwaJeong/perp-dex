// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module authority_cap::authority;

use haneul::derived_object;
use haneul::dynamic_field;
use haneul::transfer::Receiving;
use std::internal::Permit;
use std::type_name;

// === Errors and constants (original names from the published interface) ===

const EAuthorityCapAlreadyCreated: u64 = 0;
const EInvalidAuthorityRole: u64 = 1;
const EAuthorityCapRegisteredAsSingleton: u64 = 2;
const EAuthorityCapRegisteredAsMultiton: u64 = 3;

// === Types ===

public struct ADMIN {}

public struct ASSISTANT {}

public struct SingletonKey<phantom Context, phantom Role> has copy, drop, store {}

public struct MultitonKey<phantom Context, phantom Role> has copy, drop, store {}

public struct AuthorityCapKey<phantom Context, phantom Role> has copy, drop, store {}

public struct AuthorizedAuthorityCapKey<phantom Context, phantom Role> has copy, drop, store {
    cap_id: ID,
}

public struct AuthorityCap<phantom Context, phantom Role> has key, store { id: UID, `for`: ID }

// === Functions ===

public fun authorized_authority_cap_key<Context, Role>(
    cap_id: ID,
): AuthorizedAuthorityCapKey<Context, Role> {
    AuthorizedAuthorityCapKey { cap_id }
}

public fun new<Context: drop, Role: drop>(
    id: &mut UID,
    _: &Context,
    _: &Role,
    `for`: ID,
): AuthorityCap<Context, Role> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, Role> {}),
        EAuthorityCapAlreadyCreated,
    );
    assert!(
        !dynamic_field::exists(id, MultitonKey<Context, Role> {}),
        EAuthorityCapRegisteredAsMultiton,
    );
    dynamic_field::add(id, SingletonKey<Context, Role> {}, true);
    AuthorityCap {
        id: derived_object::claim(id, AuthorityCapKey<Context, Role> {}),
        `for`,
    }
}

public fun new_multiton<Context: drop, Role: drop>(
    id: &mut UID,
    _: &Context,
    _: &Role,
    `for`: ID,
    ctx: &mut TxContext,
): AuthorityCap<Context, Role> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, Role> {}),
        EAuthorityCapRegisteredAsSingleton,
    );
    let multiton_key = MultitonKey<Context, Role> {};
    if (!dynamic_field::exists(id, multiton_key)) {
        dynamic_field::add(id, multiton_key, true)
    };
    AuthorityCap { id: object::new(ctx), `for` }
}

public fun new_admin_cap<Context: drop>(
    id: &mut UID,
    _: &Context,
    `for`: ID,
): AuthorityCap<Context, ADMIN> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, ADMIN> {}),
        EAuthorityCapAlreadyCreated,
    );
    assert!(
        !dynamic_field::exists(id, MultitonKey<Context, ADMIN> {}),
        EAuthorityCapRegisteredAsMultiton,
    );
    dynamic_field::add(id, SingletonKey<Context, ADMIN> {}, true);
    AuthorityCap {
        id: derived_object::claim(id, AuthorityCapKey<Context, ADMIN> {}),
        `for`,
    }
}

public fun new_multiton_admin_cap<Context: drop>(
    id: &mut UID,
    _: &Context,
    `for`: ID,
    ctx: &mut TxContext,
): AuthorityCap<Context, ADMIN> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, ADMIN> {}),
        EAuthorityCapRegisteredAsSingleton,
    );
    let multiton_key = MultitonKey<Context, ADMIN> {};
    if (!dynamic_field::exists(id, multiton_key)) {
        dynamic_field::add(id, multiton_key, true)
    };
    AuthorityCap { id: object::new(ctx), `for` }
}

public fun new_assistant_cap<Context: drop>(
    id: &mut UID,
    _: &Context,
    `for`: ID,
): AuthorityCap<Context, ASSISTANT> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, ASSISTANT> {}),
        EAuthorityCapAlreadyCreated,
    );
    assert!(
        !dynamic_field::exists(id, MultitonKey<Context, ASSISTANT> {}),
        EAuthorityCapRegisteredAsMultiton,
    );
    dynamic_field::add(id, SingletonKey<Context, ASSISTANT> {}, true);
    AuthorityCap {
        id: derived_object::claim(id, AuthorityCapKey<Context, ASSISTANT> {}),
        `for`,
    }
}

public fun new_multiton_assistant_cap<Context: drop>(
    id: &mut UID,
    _: &Context,
    `for`: ID,
    ctx: &mut TxContext,
): AuthorityCap<Context, ASSISTANT> {
    assert!(
        !dynamic_field::exists(id, SingletonKey<Context, ASSISTANT> {}),
        EAuthorityCapRegisteredAsSingleton,
    );
    let multiton_key = MultitonKey<Context, ASSISTANT> {};
    if (!dynamic_field::exists(id, multiton_key)) {
        dynamic_field::add(id, multiton_key, true)
    };
    AuthorityCap { id: object::new(ctx), `for` }
}

public fun destroy<Context, Role>(
    cap: AuthorityCap<Context, Role>,
    _: Permit<Context>,
) {
    let AuthorityCap { id, `for`: _ } = cap;
    id.delete()
}

public fun `for`<Context, Role>(cap: &AuthorityCap<Context, Role>): ID {
    cap.`for`
}

public fun borrow_mut_id<Context, Role>(
    cap: &mut AuthorityCap<Context, Role>,
    _: Permit<Context>,
): &mut UID {
    &mut cap.id
}

public fun receive<Context, Role, T: key + store>(
    cap: &mut AuthorityCap<Context, Role>,
    to_receive: Receiving<T>,
): T {
    transfer::public_receive(&mut cap.id, to_receive)
}

public fun exists<Context, Role>(
    id: &UID,
): bool {
    derived_object::exists(id, AuthorityCapKey<Context, Role> {})
}

public fun derived_cap_id<Context, Role>(id: &UID): ID {
    let derived_address = derived_object::derive_address(
        id.to_inner(),
        AuthorityCapKey<Context, Role> {},
    );
    object::id_from_address(derived_address)
}

public fun authorize_cap<Context, Role>(
    id: &mut UID,
    cap: &AuthorityCap<Context, Role>,
) {
    dynamic_field::add(
        id,
        AuthorizedAuthorityCapKey<Context, Role> { cap_id: object::id(cap) },
        true,
    )
}

public fun deauthorize_cap<Context, Role>(
    id: &mut UID,
    cap_id: ID,
) {
    let _: bool = dynamic_field::remove(id, AuthorizedAuthorityCapKey<Context, Role> { cap_id });
}

public fun is_cap_authorized<Context, Role>(
    id: &UID,
    cap_id: ID,
): bool {
    dynamic_field::exists(id, AuthorizedAuthorityCapKey<Context, Role> { cap_id })
}

public fun is_singleton<Context, Role>(
    id: &UID,
): bool {
    dynamic_field::exists(id, SingletonKey<Context, Role> {})
}

public fun is_multiton<Context, Role>(
    id: &UID,
): bool {
    dynamic_field::exists(id, MultitonKey<Context, Role> {})
}

public fun assert_is_admin_or_assistant<Role>() {
    let role = type_name::with_defining_ids<Role>();
    assert!(
        role == type_name::with_defining_ids<ADMIN>()
            || role == type_name::with_defining_ids<ASSISTANT>(),
        EInvalidAuthorityRole,
    )
}

public fun assert_is_admin<Role>() {
    assert!(
        type_name::with_defining_ids<Role>() == type_name::with_defining_ids<ADMIN>(),
        EInvalidAuthorityRole,
    )
}
