// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: BUSL-1.1

module ordered_map::enum_option;

use std::option;

// === Errors and constants ===

#[error(code = 0x40)]
const EOptionIsSet: vector<u8> = b"The `Option` is `Some` while it should be `None`";
#[error(code = 0x41)]
const EOptionNotSet: vector<u8> = b"The `Option` is `None` while it should be `Some`";

// === Types ===

public enum Option<Element> has copy, drop, store {
    None,
    Some(Element),
}

// === Functions ===

public fun none<Element>(): Option<Element> {
    Option::None
}

public fun some<Element>(value: Element): Option<Element> {
    Option::Some(value)
}

public fun is_none<Element>(option: &Option<Element>): bool {
    match (option) { Option::Some(_) => false, _ => true }
}

public fun is_some<Element>(option: &Option<Element>): bool {
    match (option) { Option::Some(_) => true, _ => false }
}

public fun contains<Element>(option: &Option<Element>, element_ref: &Element): bool {
    match (option) { Option::Some(value) => value == element_ref, _ => false }
}

public fun borrow<Element>(option: &Option<Element>): &Element {
    match (option) { Option::Some(value) => value, _ => abort EOptionNotSet }
}

public fun borrow_with_default<Element>(option: &Option<Element>, default_ref: &Element): &Element {
    match (option) { Option::Some(value) => value, _ => default_ref }
}

public fun get_with_default<Element: copy + drop>(
    option: &Option<Element>,
    default: Element,
): Element {
    match (option) { Option::Some(value) => *value, _ => default }
}

public fun borrow_mut<Element>(option: &mut Option<Element>): &mut Element {
    match (option) { Option::Some(value) => value, _ => abort EOptionNotSet }
}

public fun destroy_with_default<Element: drop>(option: Option<Element>, default: Element): Element {
    match (option) { Option::Some(value) => value, _ => default }
}

public fun destroy_some<Element>(option: Option<Element>): Element {
    match (option) { Option::Some(value) => value, Option::None => abort EOptionNotSet }
}

public fun destroy_none<Element>(option: Option<Element>) {
    match (option) { Option::Some(_value) => abort EOptionIsSet, Option::None => () }
}

public fun assert_none<Element>(option: &Option<Element>) {
    match (option) { Option::Some(_) => abort EOptionIsSet, _ => () }
}

public fun assert_some<Element>(option: &Option<Element>) {
    match (option) { Option::None => abort EOptionNotSet, _ => () }
}

public fun from_std<Element>(option: std::option::Option<Element>): Option<Element> {
    if (option.is_none()) {
        option.destroy_none();
        return Option::None
    };
    Option::Some(option.destroy_some())
}

public fun copy_from_std<Element: copy>(option: &std::option::Option<Element>): Option<Element> {
    if (option.is_none()) {
        return Option::None
    };
    Option::Some(*option.borrow())
}

public fun to_std<Element>(option: Option<Element>): std::option::Option<Element> {
    match (option) {
        Option::None => option::none(),
        Option::Some(value) => option::some(value),
    }
}
