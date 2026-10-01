#!/usr/bin/env python3
# Copyright (c) 2026 Geunhwa Jeong
# SPDX-License-Identifier: Apache-2.0
"""Signs price updates for the `oracle_haneul` source.

The message is the BCS encoding of `oracle_haneul::price_feed_storage::PriceUpdate`, signed with
Ed25519 (RFC 8032, implemented below without dependencies so the localnet suite keeps needing
only python3). This is test tooling: the arithmetic is neither fast nor constant-time, and a
production signer must use a real library.

As a script it prints the signatures the Move unit tests of `packages/oracle_haneul` embed:
    python3 e2e/oracle_signing.py fixtures <source object id>
"""

import hashlib
import sys

MESSAGE_DOMAIN = b"haneul_oracle::PriceUpdate"

# === Ed25519 (RFC 8032, section 6) ===

_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _sha512(data: bytes) -> bytes:
    return hashlib.sha512(data).digest()


def _point_add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    e = (y1 - x1) * (y2 - x2) % _P
    f = (y1 + x1) * (y2 + x2) % _P
    g = 2 * t1 * t2 * _D % _P
    h = 2 * z1 * z2 % _P
    return ((f - e) * (h - g) % _P, (h + g) * (f + e) % _P, (h - g) * (h + g) % _P, (f - e) * (f + e) % _P)


def _point_mul(scalar: int, point):
    result = (0, 1, 1, 0)
    while scalar > 0:
        if scalar & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        scalar >>= 1
    return result


def _recover_x(y: int, sign: int) -> int:
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P)
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * pow(5, _P - 2, _P) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _compress(point) -> bytes:
    x, y, z, _ = point
    zinv = pow(z, _P - 2, _P)
    x, y = x * zinv % _P, y * zinv % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _expand(seed: bytes):
    h = _sha512(seed)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed: bytes) -> bytes:
    """The 32-byte Ed25519 public key of a 32-byte secret seed."""
    a, _ = _expand(seed)
    return _compress(_point_mul(a, _G))


def sign(seed: bytes, message: bytes) -> bytes:
    """The 64-byte Ed25519 signature of `message` under a 32-byte secret seed."""
    a, prefix = _expand(seed)
    pk = _compress(_point_mul(a, _G))
    r = int.from_bytes(_sha512(prefix + message), "little") % _L
    big_r = _compress(_point_mul(r, _G))
    h = int.from_bytes(_sha512(big_r + pk + message), "little") % _L
    s = (r + h * a) % _L
    return big_r + int.to_bytes(s, 32, "little")


# === Price update message ===


def _uleb128(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def price_update_message(source_id: str, storage_id: int, price: int, confidence: int, timestamp_ms: int) -> bytes:
    """BCS bytes of `PriceUpdate { domain, source, storage_id, price, confidence, timestamp_ms }`."""
    source = bytes.fromhex(source_id.removeprefix("0x").rjust(64, "0"))
    return (
        _uleb128(len(MESSAGE_DOMAIN))
        + MESSAGE_DOMAIN
        + source
        + storage_id.to_bytes(4, "little")
        + price.to_bytes(16, "little")
        + confidence.to_bytes(16, "little")
        + timestamp_ms.to_bytes(8, "little")
    )


def sign_price_update(seed: bytes, source_id: str, storage_id: int, price: int, confidence: int, timestamp_ms: int) -> bytes:
    return sign(seed, price_update_message(source_id, storage_id, price, confidence, timestamp_ms))


# === Fixtures for the Move unit tests ===

ONE = 10**18
# Throwaway seeds; the keys sign nothing but test fixtures.
FIXTURE_SIGNER_SEED = bytes([0x11] * 32)
FIXTURE_OTHER_SEED = bytes([0x22] * 32)

# name, seed, storage_id, price, confidence, timestamp_ms
FIXTURES = [
    ("FIRST", FIXTURE_SIGNER_SEED, 0, 68_000 * ONE, 10 * ONE, 1_000_000),
    ("SECOND", FIXTURE_SIGNER_SEED, 0, 68_500 * ONE, 10 * ONE, 1_005_000),
    ("WIDE", FIXTURE_SIGNER_SEED, 0, 68_000 * ONE, 1_360 * ONE, 1_010_000),
    ("AT_BOUND", FIXTURE_SIGNER_SEED, 0, 68_000 * ONE, 680 * ONE, 1_010_000),
    ("ZERO", FIXTURE_SIGNER_SEED, 0, 0, 0, 1_010_000),
    ("AHEAD", FIXTURE_SIGNER_SEED, 0, 68_000 * ONE, 10 * ONE, 1_013_000),
    ("TOO_FAR_AHEAD", FIXTURE_SIGNER_SEED, 0, 68_000 * ONE, 10 * ONE, 1_013_001),
    ("OTHER_FEED", FIXTURE_SIGNER_SEED, 1, 2_000 * ONE, 1 * ONE, 1_000_000),
    ("OTHER_SIGNER", FIXTURE_OTHER_SEED, 0, 68_500 * ONE, 10 * ONE, 1_005_000),
    # Step limit, from 68,000 at 1,000,000 ms: one second later the default allows 1%.
    ("STEP_UP_AT_LIMIT", FIXTURE_SIGNER_SEED, 0, 68_680 * ONE, 10 * ONE, 1_001_000),
    ("STEP_UP_OVER", FIXTURE_SIGNER_SEED, 0, 68_680 * ONE + 1, 10 * ONE, 1_001_000),
    ("STEP_DOWN_AT_LIMIT", FIXTURE_SIGNER_SEED, 0, 67_320 * ONE, 10 * ONE, 1_001_000),
    ("STEP_DOWN_OVER", FIXTURE_SIGNER_SEED, 0, 67_320 * ONE - 1, 10 * ONE, 1_001_000),
    # Half a second later the default allows 0.75%, which is 68,510.
    ("STEP_HALF_SECOND", FIXTURE_SIGNER_SEED, 0, 68_511 * ONE, 10 * ONE, 1_000_500),
    # A hundred seconds later the allowance has reached its maximum of 20%.
    ("STEP_AT_MAX", FIXTURE_SIGNER_SEED, 0, 81_600 * ONE, 10 * ONE, 1_100_000),
    ("STEP_OVER_MAX", FIXTURE_SIGNER_SEED, 0, 81_600 * ONE + 1, 10 * ONE, 1_100_000),
    # Far from the stored price, but older than it.
    ("OLD_AND_FAR", FIXTURE_SIGNER_SEED, 0, 1 * ONE, 0, 999_000),
]


def _rfc8032_self_test():
    # RFC 8032, section 7.1, test 2.
    seed = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
    assert public_key(seed).hex() == "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
    assert sign(seed, bytes.fromhex("72")).hex() == (
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
        "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
    )


def main():
    _rfc8032_self_test()
    if len(sys.argv) != 3 or sys.argv[1] != "fixtures":
        sys.exit(__doc__)
    source_id = sys.argv[2]
    print(f'const SIGNER: vector<u8> = x"{public_key(FIXTURE_SIGNER_SEED).hex()}";')
    print(f'const OTHER_SIGNER: vector<u8> = x"{public_key(FIXTURE_OTHER_SEED).hex()}";')
    for name, seed, storage_id, price, confidence, timestamp_ms in FIXTURES:
        signature = sign_price_update(seed, source_id, storage_id, price, confidence, timestamp_ms)
        print(f'const SIG_{name}: vector<u8> =\n    x"{signature.hex()}";')


if __name__ == "__main__":
    main()
