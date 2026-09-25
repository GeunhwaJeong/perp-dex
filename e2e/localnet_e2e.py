#!/usr/bin/env python3
# Copyright (c) 2026 Geunhwa Jeong
# SPDX-License-Identifier: Apache-2.0
"""Localnet end-to-end test of the Haneul perp engine in packages/.

Publishes the nine engine packages plus the `perp_e2e` helper to a running localnet, opens a
BTC/USD market collateralized in TUSD whose prices come from a hand-driven oracle source, then
trades, cancels, liquidates, collects fees and settles through real transactions, and finally runs
a market-making vault on a second market. Every amount is checked against a value derived
independently in this file. Engine state is read by simulating
`perp_e2e::probe` calls over gRPC (`grpcurl`, TransactionExecutionService/SimulateTransaction).

Start the network first:
    haneul start --with-faucet --force-regenesis
    haneul client switch --env local
    haneul client faucet
Then:
    python3 e2e/localnet_e2e.py

Needs python3 and grpcurl. The CLI is deps/bin/haneul when present, otherwise `haneul` on PATH;
set HANEUL to use another binary.

It refuses to run unless the active env is local/localnet and the chain is not Haneul mainnet.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# A local copy of the CLI in deps/bin/ wins over the one on PATH; HANEUL overrides both.
_LOCAL_CLI = ROOT / "deps/bin/haneul"
HANEUL = os.environ.get("HANEUL") or (str(_LOCAL_CLI) if _LOCAL_CLI.exists() else "haneul")
PUBFILE = ROOT / "e2e/Pub.localnet.toml"
MAINNET_CHAIN_ID = "a0053d9e"
GAS_BUDGET = 2_000_000_000
CLOCK = "@0x6"

ONE = 10**18  # ifixed 1.0
B9 = 10**9  # base size and order price decimals
TUSD_UNIT = 10**6  # TUSD has 6 decimals
FIXED_PER_TUSD_UNIT = ONE // TUSD_UNIT

PACKAGES = [
    "ifixed",
    "authority_cap",
    "ordered_map",
    "af_lp",
    "position",
    "vendor",
    "oracle_aggregator",
    "perpetuals",
    "market_making_vault",
]

# Market parameters (ifixed unless noted).
IMR = ONE // 10
MMR = ONE // 20
MAKER_FEE = 2 * 10**14  # 0.02%
TAKER_FEE = 5 * 10**14  # 0.05%
LIQ_FEE = 10**16  # 1%
IF_FEE = 5 * 10**15  # 0.5%
LOT = 1_000_000  # 0.001 BTC
TICK = B9  # $1
# Bad debt policy: no socialization (bad debt beyond the insurance fund is left to ADL), and the
# default 0.1% priority taker fee.
MAX_BAD_DEBT = 0
MAX_SOCIALIZE_MR_DECREASE = 0
PRIORITY_TAKER_FEE = 10**15

ASK, BID = True, False
GTC, FOK, POST_ONLY, IOC = 0, 1, 2, 3


class E2EError(Exception):
    pass


# ---------------------------------------------------------------- fixed-point helpers


def signed(x):
    x = int(x)
    return x - (1 << 256) if x >= (1 << 255) else x


def fmul(x, y):
    # ifixed::mul rounds toward negative infinity.
    return (x * y) // ONE


def fdiv(x, y):
    return (x * ONE) // y


def fdiv_up(x, y):
    return -((-x * ONE) // y)


def usd(x):
    return f"{x / ONE:,.6f}"


def px(dollars):
    """Order price in 9-decimal units."""
    return int(round(dollars * B9))


def fx(dollars):
    """ifixed amount from a decimal string or int."""
    from decimal import Decimal

    return int(Decimal(str(dollars)) * ONE)


# ---------------------------------------------------------------- CLI plumbing


def cli(*args):
    return subprocess.run([HANEUL, *args], capture_output=True, text=True, cwd=ROOT)


def u8(n):
    return f"{n}u8"


def u16(n):
    return f"{n}u16"


def u64(n):
    return f"{n}u64"


def u128(n):
    return f"{n}u128"


def u256(n):
    return f"{n}u256"


def b(v):
    return "true" if v else "false"


def obj(i):
    return f"@{i}"


def call(target, type_args, *args, assign=None):
    cmd = ["--move-call", target]
    if type_args:
        cmd.append("<" + ",".join(type_args) + ">")
    cmd += list(args)
    if assign:
        cmd += ["--assign", assign]
    return cmd


ABORT_RE = re.compile(
    r"aborted within function '0x[0-9a-f]+::(\w+)::(\w+)' at instruction \d+ with code (\d+)"
)


GRPC_ADDR = [None]  # host:port of the node's gRPC (served on the RPC port)


def simulate(label, cmds):
    """Builds the PTB with the CLI and simulates it over gRPC (TransactionExecutionService).

    Nothing is written on chain. The CLI's own --dry-run/--dev-inspect print tables only.
    """
    p = cli("client", "ptb", *cmds, "--gas-budget", str(GAS_BUDGET), "--serialize-unsigned-transaction")
    if p.returncode != 0:
        raise E2EError(f"{label} failed to build:\n{(p.stdout + p.stderr)[-3000:]}")
    tx = p.stdout.strip().splitlines()[-1]
    req = {
        "transaction": {"bcs": {"value": tx}},
        "read_mask": {"paths": ["transaction.effects.status", "transaction.events"]},
    }
    g = subprocess.run(
        [
            "grpcurl",
            "-plaintext",
            "-d",
            "@",
            GRPC_ADDR[0],
            "haneul.rpc.v2.TransactionExecutionService/SimulateTransaction",
        ],
        input=json.dumps(req),
        capture_output=True,
        text=True,
    )
    if g.returncode != 0:
        raise E2EError(f"{label} simulate error: {(g.stdout + g.stderr)[-2000:]}")
    res = json.loads(g.stdout)["transaction"]
    status = res["effects"]["status"]
    if not status.get("success"):
        raise E2EError(f"{label} simulation failed: {status}")
    evs = res.get("events", {}).get("events", [])
    return {"events": [{"type": e["eventType"], "parsedJson": e["json"]} for e in evs]}


def ptb(label, cmds, expect_abort=None, inspect=False):
    """Runs a PTB. `expect_abort=(module, code)` makes an abort the passing outcome."""
    if inspect:
        return simulate(label, cmds)
    args = ["client", "ptb", *cmds, "--gas-budget", str(GAS_BUDGET), "--json"]
    p = cli(*args)
    out = p.stdout + p.stderr
    if expect_abort is not None:
        m = ABORT_RE.search(out)
        got = (m.group(1), int(m.group(3))) if m else None
        ok = got == expect_abort
        check(
            f"{label}: aborts with {expect_abort[0]}::{expect_abort[1]}",
            ok,
            f"got {got}; output: {out[-600:].strip()}" if not ok else f"in {m.group(1)}::{m.group(2)}",
        )
        return None
    if p.returncode != 0:
        raise E2EError(f"{label} failed:\n{out[-3000:]}")
    j = json.loads(p.stdout)
    status = j["effects"]["status"]
    if status["status"] != "success":
        raise E2EError(f"{label} failed on chain: {status}")
    return j


def events(j, suffix):
    return [e["parsedJson"] for e in j.get("events", []) if e["type"].split("<")[0].endswith(suffix)]


def created(j, type_suffix):
    ids = [
        c["objectId"]
        for c in j["objectChanges"]
        if c["type"] == "created" and c["objectType"].split("<")[0].endswith(type_suffix)
    ]
    return ids


# ---------------------------------------------------------------- reporting

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {name}" + (f"  ({detail})" if detail else ""))


def eq(name, got, want, tol=0, fmt=usd):
    ok = abs(got - want) <= tol
    detail = f"{fmt(got)}" if ok else f"got {fmt(got)}, want {fmt(want)}, diff {got - want}"
    check(name, ok, detail)


def section(title):
    print(f"\n== {title}")


# ---------------------------------------------------------------- safety


def safety_check():
    env = cli("client", "active-env").stdout.strip()
    if env not in ("local", "localnet"):
        sys.exit(f"refusing to run: active env is '{env}', expected local/localnet")
    out = cli("client", "chain-identifier").stdout.strip().splitlines()
    chain = out[-1].split()[-1] if out else ""
    if not chain or chain == MAINNET_CHAIN_ID:
        sys.exit(f"refusing to run: chain identifier '{chain}' is mainnet or unknown")
    envs = cli("client", "envs", "--json").stdout
    try:
        rows, active = json.loads(envs)
        url = next(r["rpc"] for r in rows if r["alias"] == active)
    except Exception:
        url = ""
    if "127.0.0.1" not in url and "localhost" not in url:
        sys.exit(f"refusing to run: active env RPC '{url}' is not local")
    GRPC_ADDR[0] = url.split("://", 1)[-1].rstrip("/")
    print(f"localnet chain {chain}, env {env}, rpc {url}")
    return chain


# ---------------------------------------------------------------- publish


def publish_all():
    if PUBFILE.exists():
        PUBFILE.unlink()
    ids = {}
    for name in PACKAGES + ["perp_e2e"]:
        path = ROOT / ("e2e/perp_e2e" if name == "perp_e2e" else f"packages/{name}")
        p = subprocess.run(
            [
                HANEUL,
                "client",
                "test-publish",
                "--build-env",
                "mainnet",
                "--pubfile-path",
                str(PUBFILE),
                "--gas-budget",
                str(GAS_BUDGET),
                "--json",
            ],
            capture_output=True,
            text=True,
            cwd=path,
        )
        if p.returncode != 0:
            raise E2EError(f"publish {name} failed:\n{(p.stdout + p.stderr)[-3000:]}")
        j = json.loads(p.stdout)
        assert j["effects"]["status"]["status"] == "success", j["effects"]["status"]
        pkg = next(c["packageId"] for c in j["objectChanges"] if c["type"] == "published")
        ids[name] = {"pkg": pkg, "tx": j}
        print(f"  published {name:20s} {pkg}")
    return ids


def owned_created(j, type_substr, suffix=""):
    """First created object owned by an address (not a dynamic field) whose type contains `type_substr`."""
    for c in j["objectChanges"]:
        if (
            c["type"] == "created"
            and type_substr in c["objectType"]
            and c["objectType"].endswith(suffix)
            and isinstance(c["owner"], dict)
            and "AddressOwner" in c["owner"]
        ):
            return c["objectId"]
    raise E2EError(f"no created object matching {type_substr}")


def shared_created(j, type_suffix):
    for c in j["objectChanges"]:
        if (
            c["type"] == "created"
            and c["objectType"].endswith(type_suffix)
            and isinstance(c["owner"], dict)
            and "Shared" in c["owner"]
        ):
            return c["objectId"]
    raise E2EError(f"no shared object {type_suffix}")


# ---------------------------------------------------------------- the test


class World:
    pass


def main():
    safety_check()
    me = cli("client", "active-address").stdout.strip()
    w = World()
    w.me = me

    section("Publish")
    ids = publish_all()
    P = {k: v["pkg"] for k, v in ids.items()}
    w.P = P
    AUTH, VENDOR, ORACLE, PERP, E2E = (
        P["authority_cap"],
        P["vendor"],
        P["oracle_aggregator"],
        P["perpetuals"],
        P["perp_e2e"],
    )
    ADMIN = f"{AUTH}::authority::ADMIN"
    TUSD = f"{E2E}::tusd::TUSD"
    VK = f"{E2E}::vendor_key::E2E"
    PAUSE_GUARDIAN = f"{PERP}::authority::PAUSE_GUARDIAN"
    check("all 10 packages published", len(P) == 10)

    vendor_config = shared_created(ids["vendor"]["tx"], "::config::Config")
    vendor_pkg_admin = owned_created(ids["vendor"]["tx"], "::authority::AuthorityCap<")
    oracle_config = shared_created(ids["oracle_aggregator"]["tx"], "::config::Config")
    oracle_pkg_admin = owned_created(ids["oracle_aggregator"]["tx"], "::authority::AuthorityCap<")
    registry = shared_created(ids["perpetuals"]["tx"], "::registry::Registry")
    perp_pkg_admin = owned_created(ids["perpetuals"]["tx"], "::authority::AuthorityCap<")
    tusd_treasury = owned_created(ids["perp_e2e"]["tx"], "::coin::TreasuryCap<", "::tusd::TUSD>")
    tusd_metadata = next(
        c["objectId"]
        for c in ids["perp_e2e"]["tx"]["objectChanges"]
        if c["type"] == "created" and c["objectType"].endswith("::tusd::TUSD>") and "::coin::CoinMetadata<" in c["objectType"]
    )

    # ------------------------------------------------------------ vendor + oracle setup
    section("Vendor, oracle and market setup")
    j = ptb(
        "register vendor",
        call(f"{VENDOR}::config::register_vendor", [VK, ADMIN], obj(vendor_config), obj(vendor_pkg_admin), obj(me)),
    )
    vendor_vk_cap = owned_created(j, "::authority::AuthorityCap<")

    BTC0 = fx(100_000)
    cmds = []
    cmds += call(
        f"{VENDOR}::metadata::new",
        [VK, ADMIN],
        obj(vendor_config),
        obj(vendor_vk_cap),
        "'Haneul Perps E2E'",
        "'localnet end-to-end vendor'",
        assign="meta",
    )
    cmds += call(
        f"{VENDOR}::metadata::approve_domain_registration",
        [VK, f"{ORACLE}::authority::PACKAGE"],
        "meta",
        obj(vendor_config),
        obj(oracle_pkg_admin),
    )
    cmds += call(
        f"{ORACLE}::config::register_vendor",
        [VK, ADMIN],
        obj(oracle_config),
        obj(vendor_vk_cap),
        obj(vendor_config),
        "meta",
        assign="oracle_vk",
    )
    cmds += call(f"{PERP}::registry::set_vendor_registration", [], obj(registry), obj(perp_pkg_admin), "true")
    cmds += call(
        f"{PERP}::registry::register_vendor",
        [VK, ADMIN],
        obj(registry),
        obj(vendor_vk_cap),
        obj(vendor_config),
        "meta",
        assign="perp_vk",
    )
    cmds += call(f"{PERP}::registry::create_vendor_treasury_cap", [VK], obj(registry), "perp_vk", assign="treasury")
    cmds += call(f"{PERP}::registry::create_vendor_pause_guardian_cap", [VK], obj(registry), "perp_vk", assign="pauser")
    cmds += call(f"{E2E}::mock_source::create", [ADMIN], obj(oracle_config), obj(oracle_pkg_admin), assign="src")
    cmds += call(f"{E2E}::mock_source::authorize", [ADMIN], "src", obj(oracle_config), obj(oracle_pkg_admin))
    cmds += call(
        f"{ORACLE}::price_feed_storage::new", [VK, ADMIN], obj(oracle_config), "oracle_vk", "'BTC/USD'", assign="pfs_btc"
    )
    cmds += call(
        f"{ORACLE}::price_feed_storage::new", [VK, ADMIN], obj(oracle_config), "oracle_vk", "'TUSD/USD'", assign="pfs_tusd"
    )
    # A 1 ms TWAP window makes the feed TWAP follow the spot price between transactions.
    cmds += call(
        f"{E2E}::mock_source::new_price_feed",
        [VK, ADMIN],
        "src",
        "oracle_vk",
        obj(oracle_config),
        "pfs_btc",
        u128(BTC0),
        u64(1),
        CLOCK,
    )
    cmds += call(
        f"{E2E}::mock_source::new_price_feed",
        [VK, ADMIN],
        "src",
        "oracle_vk",
        obj(oracle_config),
        "pfs_tusd",
        u128(ONE),
        u64(1),
        CLOCK,
    )
    cmds += ["--make-move-vec", f"<{ORACLE}::price_feed_storage::PriceFeedStorage>", "[pfs_btc, pfs_tusd]", "--assign", "pfs_vec"]
    cmds += call(f"{ORACLE}::price_feed_storage::share_vec", [], "pfs_vec")
    cmds += ["--transfer-objects", "[meta, oracle_vk, perp_vk, treasury, pauser, src]", obj(me)]
    j = ptb("vendor registration, oracle source and price feeds", cmds)

    source_id = int(events(j, "::events::CreatedSource")[0]["source_id"])
    storages = {e["symbol"]: e for e in events(j, "::events::CreatedPriceFeedStorage")}
    check("oracle vendor registered", len(events(j, "::events::RegisteredVendor")) == 2)
    check("two price feed storages created", set(storages) == {"BTC/USD", "TUSD/USD"})
    check("two price feeds created", len(events(j, "::events::CreatedPriceFeed")) == 2)
    pfs_btc = storages["BTC/USD"]["price_feed_storage_obj_id"]
    pfs_tusd = storages["TUSD/USD"]["price_feed_storage_obj_id"]
    oracle_vk = owned_created(j, f"AuthorityCap<{ORACLE}::authority::VENDOR<")
    perp_vk = owned_created(j, f"AuthorityCap<{PERP}::authority::VENDOR<{VK}>, {ADMIN}>")
    perp_treasury = owned_created(j, f"{PERP}::authority::TREASURY>")
    perp_pauser = owned_created(j, f"{PERP}::authority::PAUSE_GUARDIAN>")
    source = owned_created(j, "::source::Source<")
    w.state = dict(
        registry=registry,
        pfs_btc=pfs_btc,
        pfs_tusd=pfs_tusd,
        source=source,
        oracle_config=oracle_config,
    )

    # ------------------------------------------------------------ clearing house
    def create_market(label):
        cmds = call(
            f"{PERP}::clearing_house::create_orderbook",
            [VK, ADMIN],
            obj(perp_vk),
            obj(registry),
            # Small B+tree nodes so a dozen orders already split leaves and branches.
            u64(2),
            u64(4),
            u64(4),
            u64(2),
            u64(3),
            u64(4),
            assign="ob",
        )
        # The creation parameters are a builder: the required values first, then each group.
        cmds += call(
            f"{PERP}::market::new_creation_params",
            [],
            u256(IMR),
            u256(MMR),
            u64(LOT),
            u64(TICK),
            u256(MAX_BAD_DEBT),
            u256(MAX_SOCIALIZE_MR_DECREASE),
            assign="params",
        )
        cmds += call(f"{PERP}::market::set_fees", [], "params", u256(MAKER_FEE), u256(TAKER_FEE), u256(LIQ_FEE), u256(IF_FEE))
        cmds += call(f"{PERP}::market::set_funding", [], "params", u64(60_000), u64(21_600_000))
        cmds += call(f"{PERP}::market::set_premium_twap", [], "params", u64(1_000), u64(60_000))
        cmds += call(f"{PERP}::market::set_spread_twap", [], "params", u64(1_000), u64(60_000))
        cmds += call(f"{PERP}::market::set_priority_taker_fee", [], "params", f"some({u256(PRIORITY_TAKER_FEE)})")
        cmds += call(
            f"{PERP}::clearing_house::create_clearing_house",
            [TUSD, VK, ADMIN],
            "ob",
            obj(perp_vk),
            obj(registry),
            obj(tusd_metadata),
            CLOCK,
            obj(pfs_btc),
            obj(pfs_tusd),
            u16(source_id),
            u16(source_id),
            "params",
            assign="ch",
        )
        cmds += call(f"{PERP}::clearing_house::register_market", [VK, ADMIN, TUSD], obj(registry), obj(perp_vk), "ch")
        cmds += call(f"{PERP}::clearing_house::share", [TUSD], "ch")
        j = ptb(label, cmds)
        return j, shared_created(j, f"::clearing_house::ClearingHouse<{TUSD}>")

    j, ch = create_market("create BTC/USD clearing house")
    check("clearing house created and registered", len(events(j, "::events::CreatedClearingHouse")) == 1)
    check("TUSD collateral registered", len(events(j, "::events::RegisteredCollateralInfo")) == 1)

    # ------------------------------------------------------------ accounts
    section("Accounts, deposits and allocations")
    deposits = {"M": 1_000_000, "T": 100_000, "L": 200_000, "V": 10_000}
    allocs = {"M": 500_000, "T": 20_000, "L": 100_000, "V": 3_000}
    minted = 0
    cmds = []
    for name, amount in deposits.items():
        cmds += call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(amount * TUSD_UNIT), assign=f"coin{name}")
        cmds += call(f"{PERP}::account::create_account", [TUSD], obj(registry), assign=f"acc{name}")
        cmds += call(
            f"{PERP}::account::deposit_collateral",
            [TUSD, ADMIN],
            f"acc{name}.0",
            f"acc{name}.2",
            obj(registry),
            f"coin{name}",
        )
        cmds += call(f"{PERP}::account::consume_policy_and_share_account", [TUSD], f"acc{name}.0", f"acc{name}.1")
        minted += amount * TUSD_UNIT
    cmds += ["--transfer-objects", "[" + ", ".join(f"acc{n}.2" for n in deposits) + "]", obj(me)]
    j = ptb("mint TUSD, create and fund four accounts", cmds)
    created_accounts = events(j, "::events::CreatedAccount")
    deposited = events(j, "::events::DepositedCollateral")
    check("four accounts created", len(created_accounts) == 4)
    check(
        "deposits recorded",
        [int(d["collateral"]) for d in deposited] == [a * TUSD_UNIT for a in deposits.values()],
    )
    acct = {}
    caps = [
        c["objectId"]
        for c in j["objectChanges"]
        if c["type"] == "created" and f"AuthorityCap<{PERP}::authority::ACCOUNT, {ADMIN}>" in c["objectType"]
    ]
    # Caps are created in account order; match them to accounts by the cap's `for` field.
    cap_for = {}
    for cid in caps:
        o = json.loads(cli("client", "object", cid, "--json").stdout)
        cap_for[o["content"]["for"]] = cid
    for name, ev in zip(deposits, created_accounts):
        acct[name] = dict(id=int(ev["account_id"]), obj=ev["account_obj_id"], cap=cap_for[ev["account_obj_id"]])
    check("each account has its own admin cap", len(set(a["cap"] for a in acct.values())) == 4)

    cmds = []
    for name, a in acct.items():
        cmds += call(f"{PERP}::clearing_house::create_market_position", [TUSD, ADMIN], obj(ch), obj(a["cap"]), obj(a["obj"]))
        cmds += call(
            f"{PERP}::clearing_house::allocate_collateral",
            [TUSD, ADMIN],
            obj(ch),
            obj(a["cap"]),
            obj(a["obj"]),
            u64(allocs[name] * TUSD_UNIT),
        )
    ptb("create positions and allocate collateral", cmds)

    # ------------------------------------------------------------ probes and sessions
    btc_price = [BTC0]

    def refresh_prices():
        return call(
            f"{E2E}::mock_source::set_price",
            [],
            obj(source),
            obj(oracle_config),
            obj(pfs_btc),
            u128(btc_price[0]),
            CLOCK,
        ) + call(
            f"{E2E}::mock_source::set_price",
            [],
            obj(source),
            obj(oracle_config),
            obj(pfs_tusd),
            u128(ONE),
            CLOCK,
        )

    def no_integrator():
        # Option<IntegratorInfo> is not a pure type, so `none` has to come from a Move call.
        return call("0x1::option::none", [f"{PERP}::account::IntegratorInfo"], assign="no_integrator")

    def snapshot(with_mark=True, market=None, accts=None, extra=None):
        market = market or ch
        accts = accts or acct
        cmds = refresh_prices() if with_mark else []
        for a in accts.values():
            cmds += call(f"{E2E}::probe::position", [TUSD], obj(market), u64(a["id"]))
            cmds += call(f"{E2E}::probe::account", [TUSD], obj(a["obj"]))
        cmds += call(f"{E2E}::probe::market", [TUSD], obj(market))
        if with_mark:
            cmds += call(f"{E2E}::probe::mark", [TUSD], obj(market), obj(pfs_btc), CLOCK)
        cmds += list(extra or [])
        j = ptb("snapshot", cmds, inspect=True)
        pos = {}
        for e in events(j, "::probe::PositionSnapshot"):
            pos[int(e["account_id"])] = {
                "exists": e["exists"],
                "collateral": signed(e["collateral"]),
                "base": signed(e["base"]),
                "quote": signed(e["quote"]),
                "pending_asks": signed(e["pending_asks"]),
                "pending_bids": signed(e["pending_bids"]),
                "pending_orders": int(e["pending_orders"]),
                "funding": signed(e["unsettled_funding"]),
            }
        accs = {int(e["account_id"]): int(e["collateral"]) for e in events(j, "::probe::AccountSnapshot")}
        m = events(j, "::probe::MarketSnapshot")[0]

        def opt(v):
            if v is None:
                return None
            if isinstance(v, dict):
                v = v.get("vec", [None])
                v = v[0] if v else None
            return int(v) if v is not None else None

        mkt = {
            "vault": int(m["vault_collateral"]),
            "insurance": int(m["insurance_fund"]),
            "oi": signed(m["open_interest"]),
            "fees": signed(m["fees_accrued"]),
            "funding_long": signed(m["cum_funding_long"]),
            "funding_short": signed(m["cum_funding_short"]),
            "best_ask": opt(m["best_ask"]),
            "best_bid": opt(m["best_bid"]),
            "paused": int(m["paused"]),
        }
        mark = signed(events(j, "::probe::MarkSnapshot")[0]["mark_price"]) if with_mark else None
        by_name = {n: pos[a["id"]] for n, a in accts.items()}
        acc_by_name = {n: accs[a["id"]] for n, a in accts.items()}
        return {"pos": by_name, "acc": acc_by_name, "market": mkt, "mark": mark, "raw": j}

    def invariant(s, label):
        # Vault collateral backs every position's equity at entry prices plus the fees accrued:
        # sum(base) is zero, so sum(pnl at any price) = -sum(quote).
        equity = sum(p["collateral"] + p["funding"] - p["quote"] for p in s["pos"].values())
        vault_fixed = s["market"]["vault"] * FIXED_PER_TUSD_UNIT
        diff = vault_fixed - (equity + s["market"]["fees"])
        check(
            f"{label}: vault = sum(equity) + fees accrued",
            abs(diff) <= 10 * FIXED_PER_TUSD_UNIT,
            f"diff {diff / ONE:.9f} TUSD",
        )
        net_base = sum(p["base"] for p in s["pos"].values())
        check(f"{label}: net base across positions is zero", net_base == 0, f"{net_base}")

    def session(label, who, actions, expect_abort=None, refresh=True, alloc_missing=False, dealloc_free=False, pre=None, market=None):
        a = acct[who]
        market = market or ch
        cmds = list(pre or [])
        if refresh:
            cmds += refresh_prices()
        cmds += no_integrator()
        cmds += call(
            f"{PERP}::clearing_house::start_session",
            [TUSD, ADMIN],
            obj(market),
            obj(a["cap"]),
            obj(a["obj"]),
            obj(pfs_btc),
            obj(pfs_tusd),
            "no_integrator",
            CLOCK,
            assign="hp",
        )
        for act in actions:
            cmds += act
        cmds += call(
            f"{PERP}::clearing_house::end_session",
            [TUSD, ADMIN],
            "hp",
            obj(a["cap"]),
            obj(a["obj"]),
            b(alloc_missing),
            b(dealloc_free),
            assign="res",
        )
        cmds += call(f"{PERP}::clearing_house::share", [TUSD], "res.0")
        j = ptb(label, cmds, expect_abort=expect_abort)
        return track(j) if j is not None else None

    def limit(side, size, price, otype=GTC, reduce_only=False):
        return call(
            f"{PERP}::clearing_house::place_limit_order",
            [TUSD],
            "hp",
            b(side),
            u64(size),
            u64(price),
            u64(otype),
            "none",
            b(reduce_only),
            "none",
        )

    def market_order(side, size, reduce_only=False):
        return call(f"{PERP}::clearing_house::place_market_order", [TUSD], "hp", b(side), u64(size), b(reduce_only))

    def settled_funding(j, who):
        return sum(signed(e["collateral_change_usd"]) for e in events(j, "::events::SettledFunding") if int(e["account_id"]) == acct[who]["id"])

    orders = {n: {} for n in acct}  # name -> {(side, price): order_id}, resting orders only
    name_of = {a["id"]: n for n, a in acct.items()}

    def track(j):
        """Applies a transaction's posts, fills and cancels to `orders`."""
        for e in events(j, "::events::PostedOrder"):
            oid = int(e["order_id"])
            side = ASK if oid < (1 << 127) else BID
            price = (oid >> 64) if side == ASK else ((oid >> 64) ^ 0xFFFF_FFFF_FFFF_FFFF)
            orders[name_of[int(e["account_id"])]][(side, price)] = oid
        gone = set()
        for ev in events(j, "::events::FilledMakerOrders"):
            for e in ev["events"]:
                if int(e["remaining_size"]) == 0:
                    gone.add(int(e["order_id"]))
        for e in events(j, "::events::CanceledOrder"):
            gone.add(int(e["order_id"]))
        for book in orders.values():
            for k in [k for k, v in book.items() if v in gone]:
                del book[k]
        return j

    s0 = snapshot()
    total_alloc = sum(allocs.values()) * TUSD_UNIT
    eq("vault holds all allocated collateral", s0["market"]["vault"], total_alloc, fmt=str)
    for n in acct:
        eq(f"{n} position collateral = allocation", s0["pos"][n]["collateral"], allocs[n] * ONE)
        eq(f"{n} account balance = deposit - allocation", s0["acc"][n], (deposits[n] - allocs[n]) * TUSD_UNIT, fmt=str)
    eq("mark price starts at the index", s0["mark"], BTC0)
    invariant(s0, "after allocation")

    # ------------------------------------------------------------ S1 maker ladder
    section("S1 maker posts a 12-order ladder (B+tree splits)")
    asks = [100_010 + 10 * i for i in range(6)]
    bids = [99_990 - 10 * i for i in range(6)]
    size01 = B9 // 10
    acts = [limit(ASK, size01, px(p)) for p in asks] + [limit(BID, size01, px(p)) for p in bids]
    j = session("maker ladder", "M", acts)
    check("12 PostedOrder events", len(events(j, "::events::PostedOrder")) == 12 and len(orders["M"]) == 12)
    s1 = snapshot()
    eq("best ask 100,010", s1["market"]["best_ask"], px(100_010), fmt=str)
    eq("best bid 99,990", s1["market"]["best_bid"], px(99_990), fmt=str)
    eq("M pending asks 0.6", s1["pos"]["M"]["pending_asks"], fx("0.6"))
    eq("M pending bids 0.6", s1["pos"]["M"]["pending_bids"], fx("0.6"))
    eq("M pending order count 12", s1["pos"]["M"]["pending_orders"], 12, fmt=str)
    eq("posting charges no fee", s1["pos"]["M"]["collateral"], s0["pos"]["M"]["collateral"])
    invariant(s1, "S1")

    # ------------------------------------------------------------ S2 taker market buy
    section("S2 taker market-buys 0.25 BTC across three asks")
    # New positions start at an initial margin ratio of 1.0 (no leverage): 20,000 TUSD cannot
    # carry 25,000 USD of notional until the account opts into leverage.
    session("0.25 BTC buy at the default 1x leverage", "T", [market_order(BID, 250_000_000)], expect_abort=("position", 2001))
    cmds = []
    for n in ("T", "V"):
        cmds += call(
            f"{PERP}::clearing_house::set_position_initial_margin_ratio",
            [TUSD, ADMIN],
            obj(ch),
            obj(acct[n]["cap"]),
            obj(acct[n]["obj"]),
            u256(IMR),
        )
    j = ptb("T and V opt into 10x (IMR 0.1)", cmds)
    check("two SetPositionInitialMarginRatio events", len(events(j, "::events::SetPositionInitialMarginRatio")) == 2)
    cmds = call(
        f"{PERP}::clearing_house::set_position_initial_margin_ratio",
        [TUSD, ADMIN],
        obj(ch),
        obj(acct["T"]["cap"]),
        obj(acct["T"]["obj"]),
        u256(IMR // 2),
    )
    ptb("IMR below the market's 0.1", cmds, expect_abort=("position", 2003))
    j = session("taker market buy 0.25", "T", [market_order(BID, 250_000_000)])
    fills = [(100_010, "0.1"), (100_020, "0.1"), (100_030, "0.05")]
    q2 = sum(fx(p) * fx(s) // ONE for p, s in fills)
    eq("fills cost 25,004.5 USD", q2, fx("25004.5"))
    taker_fee2 = fmul(q2, TAKER_FEE)
    maker_fee2 = sum(fmul(fx(p) * fx(s) // ONE, MAKER_FEE) for p, s in fills)
    ft = events(j, "::events::FilledTakerOrder")[0]
    eq("taker fee 0.05% = 12.50225", signed(ft["taker_fees"]), taker_fee2)
    eq("taker fee matches hand value", taker_fee2, fx("12.50225"))
    maker_fees_ev = sum(signed(e["maker_fees"]) for ev in events(j, "::events::FilledMakerOrders") for e in ev["events"])
    eq("maker fees 0.02% = 5.0009", maker_fees_ev, fx("5.0009"))
    s2 = snapshot()
    fT, fM = settled_funding(j, "T"), settled_funding(j, "M")
    eq("T base +0.25", s2["pos"]["T"]["base"], fx("0.25"))
    eq("T quote +25,004.5", s2["pos"]["T"]["quote"], q2)
    eq("T collateral = 20,000 - taker fee", s2["pos"]["T"]["collateral"], allocs["T"] * ONE - taker_fee2 + fT)
    eq("M base -0.25", s2["pos"]["M"]["base"], -fx("0.25"))
    eq("M quote -25,004.5", s2["pos"]["M"]["quote"], -q2)
    eq("M collateral = 500,000 - maker fees", s2["pos"]["M"]["collateral"], s1["pos"]["M"]["collateral"] - maker_fee2 + fM, tol=2)
    eq("M pending asks 0.35", s2["pos"]["M"]["pending_asks"], fx("0.35"))
    eq("M pending orders 10", s2["pos"]["M"]["pending_orders"], 10, fmt=str)
    eq("fees accrued 17.50315", s2["market"]["fees"], taker_fee2 + maker_fee2, tol=2)
    eq("open interest 0.25", s2["market"]["oi"], fx("0.25"))
    eq("best ask now 100,030 (partial fill kept)", s2["market"]["best_ask"], px(100_030), fmt=str)
    invariant(s2, "S2")

    # ------------------------------------------------------------ S3 limit crosses then rests
    section("S3 taker limit bid crosses 0.05 and rests 0.05")
    j = session("taker limit bid 0.1 @ 100,030", "T", [limit(BID, 100_000_000, px(100_030))])
    check("T rests one bid at 100,030", list(orders["T"]) == [(BID, px(100_030))])
    check("M has 9 resting orders left", len(orders["M"]) == 9)
    q3 = fx(100_030) * fx("0.05") // ONE
    taker_fee3 = fmul(q3, TAKER_FEE)
    maker_fee3 = fmul(q3, MAKER_FEE)
    s3 = snapshot()
    fT = settled_funding(j, "T")
    eq("T base 0.30", s3["pos"]["T"]["base"], fx("0.3"))
    eq("T quote 30,006", s3["pos"]["T"]["quote"], q2 + q3)
    eq("T pending bid 0.05", s3["pos"]["T"]["pending_bids"], fx("0.05"))
    eq("T collateral -2.50075", s3["pos"]["T"]["collateral"], s2["pos"]["T"]["collateral"] - taker_fee3 + fT)
    eq("M pending orders 9", s3["pos"]["M"]["pending_orders"], 9, fmt=str)
    eq("best bid is T's 100,030", s3["market"]["best_bid"], px(100_030), fmt=str)
    eq("best ask 100,040", s3["market"]["best_ask"], px(100_040), fmt=str)
    eq("fees accrued +3.50105", s3["market"]["fees"] - s2["market"]["fees"], taker_fee3 + maker_fee3, tol=2)
    invariant(s3, "S3")

    # ------------------------------------------------------------ S4 rejections
    section("S4 rejected actions leave state untouched")
    CH_MOD = "clearing_house"
    session("post-only bid that would cross", "T", [limit(BID, 10_000_000, px(100_040), POST_ONLY)], expect_abort=(CH_MOD, 47))
    session("fill-or-kill 5 BTC", "T", [limit(BID, 5 * B9, px(100_060), FOK)], expect_abort=(CH_MOD, 46))
    session("price off the $1 tick", "T", [limit(BID, 10_000_000, px(99_000.5))], expect_abort=(CH_MOD, 20))
    session("size off the 0.001 lot", "T", [limit(BID, 1_500_000, px(99_000))], expect_abort=(CH_MOD, 19))
    session("market buy beyond book depth", "T", [market_order(BID, B9)], expect_abort=(CH_MOD, 45))
    session("reduce-only bid on a long", "T", [market_order(BID, 10_000_000, reduce_only=True)], expect_abort=(CH_MOD, 9))
    session("empty session", "T", [], expect_abort=(CH_MOD, 11))
    # 3 BTC more of bids needs 33,500 of initial margin but only 16,750 of maintenance margin,
    # so it reaches the initial margin check; 5 BTC is already below maintenance.
    session("3 BTC resting bid beyond initial margin", "T", [limit(BID, 3 * B9, px(99_000))], expect_abort=("position", 2001))
    session("5 BTC resting bid below maintenance margin", "T", [limit(BID, 5 * B9, px(99_000))], expect_abort=(CH_MOD, 57))
    # Another account's cap.
    a_t, a_m = acct["T"], acct["M"]
    cmds = refresh_prices() + no_integrator() + call(
        f"{PERP}::clearing_house::start_session",
        [TUSD, ADMIN],
        obj(ch),
        obj(a_m["cap"]),
        obj(a_t["obj"]),
        obj(pfs_btc),
        obj(pfs_tusd),
        "no_integrator",
        CLOCK,
        assign="hp",
    )
    cmds += limit(BID, 10_000_000, px(99_000))
    cmds += call(f"{PERP}::clearing_house::end_session", [TUSD, ADMIN], "hp", obj(a_m["cap"]), obj(a_t["obj"]), "false", "false", assign="res")
    cmds += call(f"{PERP}::clearing_house::share", [TUSD], "res.0")
    ptb("M's cap on T's account", cmds, expect_abort=("account", 4000))
    session("liquidating a healthy position", "L", [call(f"{PERP}::clearing_house::liquidate", [TUSD], "hp", u64(acct["T"]["id"]), "ids")],
            pre=["--make-move-vec", "<u128>", "[]", "--assign", "ids"], expect_abort=(CH_MOD, 38))
    session("self-liquidation", "L", [call(f"{PERP}::clearing_house::liquidate", [TUSD], "hp", u64(acct["L"]["id"]), "ids")],
            pre=["--make-move-vec", "<u128>", "[]", "--assign", "ids"], expect_abort=(CH_MOD, 8))
    print("  waiting 11 s so the BTC price goes stale (tolerance 10 s)")
    time.sleep(11)
    session("session on a stale index price", "T", [limit(BID, 10_000_000, px(99_000))], refresh=False, expect_abort=("market", 1000))
    s4 = snapshot()
    check("positions unchanged after rejections", s4["pos"] == s3["pos"])
    check("market unchanged after rejections", {k: v for k, v in s4["market"].items()} == s3["market"])

    # ------------------------------------------------------------ S5 cancels
    section("S5 cancel resting orders")
    m_best_bid = orders["M"][(BID, px(99_990))]
    t_bid = orders["T"][(BID, px(100_030))]
    cmds = ["--make-move-vec", "<u128>", f"[{t_bid}u128]", "--assign", "tids"]
    cmds += call(f"{PERP}::clearing_house::cancel_orders", [TUSD, ADMIN], obj(ch), obj(acct["M"]["cap"]), obj(acct["M"]["obj"]), "tids")
    ptb("M cancels T's live order", cmds, expect_abort=("orderbook", 3000))
    cmds = ["--make-move-vec", "<u128>", f"[{m_best_bid}u128]", "--assign", "mids"]
    cmds += call(f"{PERP}::clearing_house::cancel_orders", [TUSD, ADMIN], obj(ch), obj(acct["M"]["cap"]), obj(acct["M"]["obj"]), "mids")
    cmds += ["--make-move-vec", "<u128>", f"[{t_bid}u128]", "--assign", "tids"]
    cmds += call(f"{PERP}::clearing_house::cancel_orders", [TUSD, ADMIN], obj(ch), obj(acct["T"]["cap"]), obj(acct["T"]["obj"]), "tids")
    j = track(ptb("cancel M 99,990 bid and T 100,030 bid", cmds))
    check("two CanceledOrder events", len(events(j, "::events::CanceledOrder")) == 2)
    check("M 8 resting, T none", len(orders["M"]) == 8 and not orders["T"])
    s5 = snapshot()
    eq("M pending bids 0.5", s5["pos"]["M"]["pending_bids"], fx("0.5"))
    eq("M pending orders 8", s5["pos"]["M"]["pending_orders"], 8, fmt=str)
    eq("T pending bids 0", s5["pos"]["T"]["pending_bids"], 0)
    eq("T pending orders 0", s5["pos"]["T"]["pending_orders"], 0, fmt=str)
    eq("best bid 99,980", s5["market"]["best_bid"], px(99_980), fmt=str)
    invariant(s5, "S5")

    # ------------------------------------------------------------ S6 price up, maker requotes, taker closes
    section("S6 index to 101,000, maker requotes, taker closes with profit")
    btc_price[0] = fx(101_000)
    m_ids = list(orders["M"].values())
    pre = ["--make-move-vec", "<u128>", "[" + ", ".join(f"{i}u128" for i in m_ids) + "]", "--assign", "mids"]
    pre += call(f"{PERP}::clearing_house::cancel_orders", [TUSD, ADMIN], obj(ch), obj(acct["M"]["cap"]), obj(acct["M"]["obj"]), "mids")
    asks6 = [101_010 + 10 * i for i in range(6)]
    bids6 = [100_990 - 10 * i for i in range(6)]
    acts = [limit(ASK, size01, px(p)) for p in asks6] + [limit(BID, size01, px(p)) for p in bids6]
    j = session("M cancels 8 and requotes around 101,000", "M", acts, pre=pre)
    check("8 cancels + 12 posts", len(events(j, "::events::CanceledOrder")) == 8 and len(orders["M"]) == 12)
    s6a = snapshot()
    j = session("T reduce-only market sell 0.30", "T", [market_order(ASK, 300_000_000, reduce_only=True)])
    fills6 = [(100_990, "0.1"), (100_980, "0.1"), (100_970, "0.1")]
    q6 = sum(fx(p) * fx(s) // ONE for p, s in fills6)
    eq("sell proceeds 30,294", q6, fx(30_294))
    pnl6 = q6 - (q2 + q3)
    eq("T realized pnl +288", pnl6, fx(288))
    ft = events(j, "::events::FilledTakerOrder")[0]
    eq("taker pnl event +288", signed(ft["taker_pnl"]), pnl6)
    taker_fee6 = fmul(q6, TAKER_FEE)
    maker_fee6 = sum(fmul(fx(p) * fx(s) // ONE, MAKER_FEE) for p, s in fills6)
    eq("taker fee 15.147", taker_fee6, fx("15.147"))
    s6 = snapshot()
    fT = settled_funding(j, "T")
    fM = settled_funding(j, "M")
    eq("T flat", s6["pos"]["T"]["base"], 0)
    eq("T quote 0", s6["pos"]["T"]["quote"], 0)
    eq("T collateral += pnl - fee", s6["pos"]["T"]["collateral"], s6a["pos"]["T"]["collateral"] + pnl6 - taker_fee6 + fT)
    eq("M flat", s6["pos"]["M"]["base"], 0)
    eq("M collateral -= 288 + maker fees", s6["pos"]["M"]["collateral"], s6a["pos"]["M"]["collateral"] - pnl6 - maker_fee6 + fM, tol=2)
    eq("open interest back to 0", s6["market"]["oi"], 0)
    invariant(s6, "S6")

    # T takes everything back to its wallet.
    cmds = refresh_prices()
    cmds += call(
        f"{PERP}::clearing_house::deallocate_free_collateral",
        [TUSD, ADMIN],
        obj(ch),
        obj(acct["T"]["cap"]),
        obj(acct["T"]["obj"]),
        obj(pfs_btc),
        obj(pfs_tusd),
        CLOCK,
    )
    j = ptb("T deallocates free collateral", cmds)
    dealloc = int(events(j, "::events::DeallocatedCollateral")[0]["collateral"])
    t_coll_units = (s6["pos"]["T"]["collateral"] + settled_funding(j, "T")) // FIXED_PER_TUSD_UNIT
    eq("T deallocated its whole collateral (floor to 1e-6)", dealloc, t_coll_units, fmt=str)
    t_total = s6["acc"]["T"] + dealloc
    j = ptb(
        "T withdraws to wallet",
        call(f"{PERP}::account::withdraw_collateral", [TUSD], obj(acct["T"]["obj"]), obj(acct["T"]["cap"]), obj(registry), u64(t_total), assign="c")
        + ["--transfer-objects", "[c]", obj(me)],
    )
    # 100,000 deposited - 12.50225 - 2.50075 - 15.147 fees + 288 pnl, plus whatever funding T
    # settled along the way (T_funding, read from SettledFunding events).
    T_funding = s6["pos"]["T"]["collateral"] + settled_funding(j, "T") - (
        allocs["T"] * ONE - taker_fee2 - taker_fee3 - taker_fee6 + pnl6
    )
    eq("T withdrew 100,257.85 + funding", t_total, (fx("100257.85") + T_funding) // FIXED_PER_TUSD_UNIT, fmt=str)
    check("T funding over the whole trade is under 1 TUSD", abs(T_funding) < ONE, usd(T_funding))
    s6w = snapshot()
    eq("T account empty", s6w["acc"]["T"], 0, fmt=str)
    invariant(s6w, "S6 after withdrawal")

    # ------------------------------------------------------------ S7 liquidation
    section("S7 victim opens 10x long, index drops to 92,000, liquidator takes over")
    j = session("V market buy 0.25", "V", [market_order(BID, 250_000_000)])
    fills7 = [(101_010, "0.1"), (101_020, "0.1"), (101_030, "0.05")]
    q7 = sum(fx(p) * fx(s) // ONE for p, s in fills7)
    eq("V cost 25,254.5", q7, fx("25254.5"))
    taker_fee7 = fmul(q7, TAKER_FEE)
    maker_fee7 = sum(fmul(fx(p) * fx(s) // ONE, MAKER_FEE) for p, s in fills7)
    s7a = snapshot()
    eq("V collateral 2,987.37275", s7a["pos"]["V"]["collateral"], allocs["V"] * ONE - taker_fee7 + settled_funding(j, "V"))

    # Empty the book so the mark price follows the index.
    # 12 posted in S6, 3 bids filled by T, 2 asks filled (one partially) by V.
    check("M has 7 resting orders", len(orders["M"]) == 7, f"{sorted(orders['M'])}")
    m_ids = list(orders["M"].values())
    cmds = ["--make-move-vec", "<u128>", "[" + ", ".join(f"{i}u128" for i in m_ids) + "]", "--assign", "mids"]
    cmds += call(f"{PERP}::clearing_house::cancel_orders", [TUSD, ADMIN], obj(ch), obj(acct["M"]["cap"]), obj(acct["M"]["obj"]), "mids")
    j = track(ptb("M cancels its remaining 7 orders", cmds))
    check("7 cancels, M book empty", len(events(j, "::events::CanceledOrder")) == 7 and not orders["M"])
    s7b = snapshot()
    check("book empty", s7b["market"]["best_ask"] is None and s7b["market"]["best_bid"] is None)

    session(
        "liquidate V while still healthy at 101,000",
        "L",
        [call(f"{PERP}::clearing_house::liquidate", [TUSD], "hp", u64(acct["V"]["id"]), "ids")],
        pre=["--make-move-vec", "<u128>", "[]", "--assign", "ids"],
        expect_abort=(CH_MOD, 38),
    )

    btc_price[0] = fx(92_000)
    pre_liq = snapshot()
    V0 = pre_liq["pos"]["V"]
    L0 = pre_liq["pos"]["L"]
    j = session(
        "L liquidates V at 92,000",
        "L",
        [call(f"{PERP}::clearing_house::liquidate", [TUSD], "hp", u64(acct["V"]["id"]), "ids")],
        pre=["--make-move-vec", "<u128>", "[]", "--assign", "ids"],
    )
    lp = events(j, "::events::LiquidatedPosition")[0]
    mark = signed(lp["mark_price"])
    check("liquidation mark within $50 of the 92,000 index", abs(mark - fx(92_000)) <= fx(50), usd(mark))

    # Independent recomputation of the liquidation (no collateral haircut).
    vf = [e for e in events(j, "::events::SettledFunding") if int(e["account_id"]) == acct["V"]["id"]]
    c = signed(vf[0]["collateral_after"]) if vf else V0["collateral"]
    b0, q0 = V0["base"], V0["quote"]
    upnl = fmul(mark, b0) - q0
    notional = fmul(mark, b0)
    mi_pm = fmul(fmul(b0, mark), IMR)
    margin = c + upnl
    check("V below maintenance before liquidation", margin < fmul(fmul(b0, mark), MMR), f"margin {usd(margin)}")
    shortfall = (mi_pm + 1) - (upnl + c)
    alpha = fdiv_up(shortfall, mi_pm - fmul(LIQ_FEE + IF_FEE, notional))
    check("partial liquidation fraction in (0, 1)", 0 < alpha < ONE, f"alpha {alpha / ONE:.6f}")
    size = fmul(alpha, b0) // B9 + 1
    size = min(-(-size // LOT) * LOT, b0 // B9)

    def reduce(b, q, c, size_b9):
        """One `reduce_liquidated_position` step on a long, at the liquidation mark price."""
        base_l = size_b9 * B9
        quote_l = fmul(base_l, mark)
        closed = -(-(q * base_l) // b)
        pnl_l = quote_l - closed
        b, q = b - base_l, q - closed
        liq_l = fmul(LIQ_FEE, quote_l)
        if_l = fmul(IF_FEE, quote_l)
        c_after = c + pnl_l - liq_l
        value = c_after + fmul(b, mark) - q
        capacity = min(c_after, value) if (value > 0 and c_after >= 0) else 0
        if_l = min(if_l, capacity)
        c = c_after - if_l
        return b, q, c, base_l, quote_l, pnl_l, liq_l, if_l

    b1, q1, c1, base_liq, quote_liq, pnl, liq_fees, if_fees = reduce(b0, q0, c, size)
    if c1 + fmul(b1, mark) - q1 < fmul(fmul(b1, mark), IMR):
        # Still under initial margin: the rest is liquidated too.
        b1, q1, c1, bx, qx, px_, lx, ix = reduce(b1, q1, c1, b1 // B9)
        base_liq, quote_liq, pnl, liq_fees, if_fees = base_liq + bx, quote_liq + qx, pnl + px_, liq_fees + lx, if_fees + ix
    eq("base liquidated (alpha formula, lot-rounded)", signed(lp["base_liquidated"]), base_liq, fmt=lambda x: f"{x / ONE:.3f} BTC")
    eq("quote liquidated = base * mark", signed(lp["quote_liquidated"]), quote_liq)
    eq("liqee pnl", signed(lp["liqee_pnl"]), pnl)
    eq("liquidation fee 1%", signed(lp["liquidation_fees"]), liq_fees)
    eq("insurance fund fee 0.5%", signed(lp["insurance_fund_fees"]), if_fees)
    eq("no bad debt", signed(lp["bad_debt"]), 0)
    post = snapshot()
    V1, L1 = post["pos"]["V"], post["pos"]["L"]
    eq("V base reduced", V1["base"], b1)
    eq("V quote reduced", V1["quote"], q1)
    eq("V collateral = before + pnl - fees", V1["collateral"], c1)
    v_margin = V1["collateral"] + fmul(mark, V1["base"]) - V1["quote"]
    check("V back above initial margin after partial liquidation", v_margin >= fmul(fmul(V1["base"], mark), IMR), f"margin {usd(v_margin)} vs IMR {usd(fmul(fmul(V1['base'], mark), IMR))}")
    lf = [e for e in events(j, "::events::SettledFunding") if int(e["account_id"]) == acct["L"]["id"]]
    l_coll = signed(lf[0]["collateral_after"]) if lf else L0["collateral"]
    eq("L took over the long", L1["base"], base_liq)
    eq("L entry quote = quote liquidated", L1["quote"], quote_liq)
    eq("L collateral += liquidation fee", L1["collateral"], l_coll + liq_fees)
    eq("insurance fund += 0.5% fee", post["market"]["insurance"] - pre_liq["market"]["insurance"], if_fees // FIXED_PER_TUSD_UNIT, tol=1, fmt=str)
    invariant(post, "S7")

    # ------------------------------------------------------------ S8 treasury
    section("S8 fees, insurance fund, pause")
    fees_hand = taker_fee2 + maker_fee2 + taker_fee3 + maker_fee3 + taker_fee6 + maker_fee6 + taker_fee7 + maker_fee7
    eq("fees accrued = every taker and maker fee so far (59.88815)", post["market"]["fees"], fees_hand, tol=8)
    eq("hand total", fees_hand, fx("59.88815"))
    j = ptb(
        "vendor treasury withdraws fees",
        call(f"{PERP}::clearing_house::withdraw_fees", [TUSD, VK], obj(ch), obj(perp_treasury), obj(registry), assign="f")
        + ["--transfer-objects", "[f]", obj(me)],
    )
    s8 = snapshot()
    eq("withdrew 59.888150 TUSD", post["market"]["vault"] - s8["market"]["vault"], 59_888_150, fmt=str)
    check("fees accrued left below one TUSD unit", 0 <= s8["market"]["fees"] < FIXED_PER_TUSD_UNIT, f"{s8['market']['fees']}")
    invariant(s8, "S8 after fee withdrawal")

    cmds = call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(1_000 * TUSD_UNIT), assign="d")
    cmds += call(f"{PERP}::clearing_house::donate_to_insurance_fund", [TUSD], obj(ch), "d")
    minted += 1_000 * TUSD_UNIT
    ptb("donate 1,000 TUSD to the insurance fund", cmds)
    s8b = snapshot()
    eq("insurance fund +1,000", s8b["market"]["insurance"] - s8["market"]["insurance"], 1_000 * TUSD_UNIT, fmt=str)

    ptb("vendor pause guardian pauses", call(f"{PERP}::clearing_house::pause_market", [TUSD, VK, PAUSE_GUARDIAN], obj(ch), obj(perp_pauser), obj(registry), u8(1)))
    session("trading while paused", "L", [market_order(ASK, 10_000_000, reduce_only=True)], expect_abort=(CH_MOD, 32))
    ptb("vendor admin resumes", call(f"{PERP}::clearing_house::resume_market", [TUSD, VK, ADMIN], obj(ch), obj(perp_vk), obj(registry)))
    s8c = snapshot()
    eq("market resumed", s8c["market"]["paused"], 0, fmt=str)

    # ------------------------------------------------------------ S9 settlement
    section("S9 close the market and settle every position at 95,000")
    settle = fx(95_000)
    cmds = call(f"{PERP}::clearing_house::close_market", [VK, ADMIN, TUSD], obj(ch), obj(perp_vk), obj(registry), CLOCK)
    cmds += call(f"{PERP}::clearing_house::set_settlement_prices", [VK, ADMIN, TUSD], obj(ch), obj(perp_vk), obj(registry), u256(settle), u256(ONE))
    cmds += call(f"{PERP}::clearing_house::enable_settlement", [VK, ADMIN, TUSD], obj(ch), obj(perp_vk), obj(registry))
    ptb("close market, set and enable settlement prices", cmds)
    session("trading after close", "L", [market_order(ASK, 10_000_000, reduce_only=True)], expect_abort=(CH_MOD, 32))
    s9a = snapshot(with_mark=False)
    m9 = s9a["market"]
    print(f"    cum funding long {m9['funding_long'] / ONE:+.12f}, short {m9['funding_short'] / ONE:+.12f}")
    cmds = ["--make-move-vec", "<u128>", "[]", "--assign", "none_ids"]
    for n, a in acct.items():
        cmds += call(f"{PERP}::clearing_house::close_position_at_settlement_prices", [TUSD], obj(ch), obj(a["obj"]), "none_ids")
    j = ptb("settle all four positions", cmds)
    closed = {int(e["account_id"]): e for e in events(j, "::events::ClosedPositionAtSettlementPrices")}
    check("four settlements", len(closed) == 4)
    s9 = snapshot(with_mark=False)
    for n, a in acct.items():
        p = s9a["pos"][n]
        sf = [e for e in events(j, "::events::SettledFunding") if int(e["account_id"]) == a["id"]]
        coll = signed(sf[0]["collateral_after"]) if sf else p["collateral"]
        print(f"    {n}: base {p['base'] / ONE:+.3f}, funding settled {usd(coll - p['collateral'])}, probe's unsettled funding {usd(p['funding'])}")
        eq(f"{n} funding settled = probe's unsettled funding", coll - p["collateral"], p["funding"], tol=10**6)
        pnl = fmul(p["base"], settle) - p["quote"] if p["base"] > 0 else (-(fmul(-p["base"], settle)) - p["quote"] if p["base"] < 0 else 0)
        want = (coll + pnl) // FIXED_PER_TUSD_UNIT
        eq(f"{n} settles to collateral + pnl at 95,000", int(closed[a["id"]]["deallocated_collateral"]), want, tol=1, fmt=str)
        eq(f"{n} position flat and empty", abs(s9["pos"][n]["base"]) + abs(s9["pos"][n]["collateral"]), 0, tol=FIXED_PER_TUSD_UNIT)
        eq(f"{n} account balance += settlement", s9["acc"][n] - s9a["acc"][n], int(closed[a["id"]]["deallocated_collateral"]), fmt=str)
    check("vault left with dust only", s9["market"]["vault"] <= 10, f"{s9['market']['vault']} units")

    # Everyone withdraws; total TUSD must equal what was minted.
    cmds = []
    for n, a in acct.items():
        amt = s9["acc"][n]
        if amt:
            cmds += call(f"{PERP}::account::withdraw_collateral", [TUSD], obj(a["obj"]), obj(a["cap"]), obj(registry), u64(amt), assign=f"w{n}")
            cmds += ["--transfer-objects", f"[w{n}]", obj(me)]
    ptb("withdraw every account", cmds)
    s_end = snapshot(with_mark=False)
    bal = json.loads(cli("client", "balance", "--coin-type", TUSD, "--json").stdout)
    wallet = _wallet_total(bal)
    total = wallet + sum(s_end["acc"].values()) + s_end["market"]["vault"] + s_end["market"]["insurance"]
    eq("TUSD conserved: wallet + accounts + vault + insurance = minted", total, minted, fmt=str)

    # ------------------------------------------------------------ S10 market-making vault
    section("S10 market-making vault on a second BTC/USD market")
    MMV = P["market_making_vault"]
    VLP = f"{E2E}::vlp::VLP"
    LOCK_MS, FORCE_DELAY_MS, OWNER_FEE = 20_000, 10_000, ONE // 10
    vault_config = shared_created(ids["market_making_vault"]["tx"], "::config::Config")
    vault_pkg_admin = owned_created(ids["market_making_vault"]["tx"], "::authority::AuthorityCap<")
    vlp_treasury = owned_created(ids["perp_e2e"]["tx"], "::coin::TreasuryCap<", "::vlp::VLP>")
    vlp_metadata = next(
        c["objectId"]
        for c in ids["perp_e2e"]["tx"]["objectChanges"]
        if c["type"] == "created" and "::coin::CoinMetadata<" in c["objectType"] and c["objectType"].endswith("::vlp::VLP>")
    )
    btc_price[0] = BTC0
    j, ch2 = create_market("create a second BTC/USD clearing house")
    check("second market created", len(events(j, "::events::CreatedClearingHouse")) == 1)

    cmds = call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(200_000 * TUSD_UNIT), assign="c")
    cmds += call(f"{PERP}::account::deposit_collateral", [TUSD, ADMIN], obj(acct["M"]["obj"]), obj(acct["M"]["cap"]), obj(registry), "c")
    cmds += call(f"{PERP}::clearing_house::create_market_position", [TUSD, ADMIN], obj(ch2), obj(acct["M"]["cap"]), obj(acct["M"]["obj"]))
    cmds += call(
        f"{PERP}::clearing_house::allocate_collateral",
        [TUSD, ADMIN],
        obj(ch2),
        obj(acct["M"]["cap"]),
        obj(acct["M"]["obj"]),
        u64(100_000 * TUSD_UNIT),
    )
    minted += 200_000 * TUSD_UNIT
    ptb("M funds a position on the second market", cmds)
    acts = [limit(ASK, size01, px(p)) for p in asks] + [limit(BID, size01, px(p)) for p in bids]
    session("M quotes the same ladder on the second market", "M", acts, market=ch2)

    def create_vault(lock_units):
        cmds = refresh_prices()
        cmds += call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(lock_units), assign="lock")
        cmds += call(
            f"{MMV}::interface::create_vault",
            [VLP, TUSD],
            obj(registry),
            obj(vault_config),
            obj(vlp_treasury),
            "@0xc",
            obj(vlp_metadata),
            obj(tusd_metadata),
            obj(pfs_tusd),
            u64(LOCK_MS),
            u256(OWNER_FEE),
            u64(FORCE_DELAY_MS),
            "lock",
            "'E2E Vault'",
            "'localnet market-making vault'",
            "none",
            "none",
            "none",
            "none",
            "none",
            CLOCK,
        )
        return cmds

    ptb("vault with $3 of owner liquidity (max $2)", create_vault(3 * TUSD_UNIT), expect_abort=("vault", 51))
    j = ptb("create the vault with $1 of owner-locked liquidity", create_vault(TUSD_UNIT))
    minted += TUSD_UNIT
    cv = events(j, "::events::CreateVault")[0]
    vault_id = cv["vault_id"]
    va = events(j, "::events::CreatedAccount")[0]
    vacct = dict(id=int(va["account_id"]), obj=va["account_obj_id"])
    name_of[vacct["id"]] = "VAULT"
    orders["VAULT"] = {}
    vault_admin = owned_created(j, f"{MMV}::authority::VAULT<{VLP}>, {ADMIN}>")
    vault_treasury = owned_created(j, f"{MMV}::authority::VAULT<{VLP}>, {MMV}::authority::TREASURY>")
    eq("initial liquidity 1 TUSD", int(cv["initial_liquidity"]), TUSD_UNIT, fmt=str)
    eq("LP decimals match TUSD", int(cv["lp_coin_decimals"]), 6, fmt=str)
    vault_accts = {"M": acct["M"], "VAULT": vacct}

    def vault_snap(lp_coins=(), with_mark=True):
        extra = call(f"{E2E}::probe::vault", [VLP, TUSD], obj(vault_id))
        for c in lp_coins:
            extra += call(f"{E2E}::probe::user_lp", [VLP], obj(c))
        s = snapshot(with_mark=with_mark, market=ch2, accts=vault_accts, extra=extra)
        s["lp_supply"] = int(events(s["raw"], "::probe::VaultSnapshot")[0]["lp_supply"])
        s["user_lp"] = [int(e["lp"]) for e in events(s["raw"], "::probe::UserLpSnapshot")]
        return s

    v0 = vault_snap()
    eq("owner-locked LP minted one-to-one", v0["lp_supply"], TUSD_UNIT, fmt=str)
    eq("vault account holds the locked TUSD", v0["acc"]["VAULT"], TUSD_UNIT, fmt=str)

    def lp_for(provided_units, supply_units, vault_value):
        """end_deposit_session: LP = supply * provided value / vault value, rounded down."""
        provided_value = fmul(provided_units * FIXED_PER_TUSD_UNIT, ONE)
        lp_supply = supply_units * B9
        lp = fdiv(fmul(provided_value, lp_supply), vault_value) // B9
        lp_fixed = lp * B9
        required = -(-(-(-(lp_fixed * vault_value) // ONE) * ONE) // lp_supply)  # div_up(mul_up(lp, v), supply)
        provided_fixed = provided_units * FIXED_PER_TUSD_UNIT
        if required >= provided_fixed:
            taken = provided_units
        else:
            taken = required // FIXED_PER_TUSD_UNIT
            if taken * FIXED_PER_TUSD_UNIT != required:
                taken += 1
        return lp, taken

    def deposit(label, units, process=(), expect_abort=None):
        cmds = refresh_prices()
        cmds += call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(units), assign="c")
        cmds += call(
            f"{MMV}::interface::start_deposit_session",
            [VLP, TUSD],
            obj(vault_id),
            obj(vault_config),
            obj(vacct["obj"]),
            obj(pfs_tusd),
            "c",
            CLOCK,
            assign="ds",
        )
        for m in process:
            cmds += call(f"{MMV}::interface::process_clearing_house_for_deposit", [VLP, TUSD], "ds", obj(m), obj(pfs_btc), CLOCK)
        cmds += call(f"{MMV}::interface::end_deposit_session", [VLP, TUSD], "ds", obj(vault_config), u64(0), obj(registry), assign="lp")
        cmds += ["--transfer-objects", "[lp]", obj(me)]
        return ptb(label, cmds, expect_abort=expect_abort)

    deposit("deposit of 0.5 TUSD (minimum $0.95)", TUSD_UNIT // 2, expect_abort=("vault", 26))
    j = deposit("user deposits 10,000 TUSD", 10_000 * TUSD_UNIT)
    minted += 10_000 * TUSD_UNIT
    t_dep1 = time.time()
    ud = events(j, "::events::UserDeposit")[0]
    lp1_obj = owned_created(j, "::vault::UserLpCoin<")
    want_lp, want_taken = lp_for(10_000 * TUSD_UNIT, v0["lp_supply"], v0["acc"]["VAULT"] * FIXED_PER_TUSD_UNIT)
    eq("vault valued at its 1 TUSD before the deposit", signed(ud["vault_balance_value"]), ONE)
    eq("10,000 LP minted (1:1 while the vault holds only cash)", int(ud["lp_coin_minted"]), want_lp, fmt=str)
    eq("hand value 10,000 LP", want_lp, 10_000 * TUSD_UNIT, fmt=str)
    eq("whole deposit taken", int(ud["provided_balance"]), want_taken, fmt=str)
    v1 = vault_snap([lp1_obj])
    eq("LP supply 10,001", v1["lp_supply"], 10_001 * TUSD_UNIT, fmt=str)
    eq("user LP coin holds 10,000", v1["user_lp"][0], 10_000 * TUSD_UNIT, fmt=str)
    eq("vault account 10,001 TUSD", v1["acc"]["VAULT"], 10_001 * TUSD_UNIT, fmt=str)

    def withdraw_request(label, lp_obj, amount, expect_abort=None):
        cmds = call(
            f"{MMV}::interface::create_withdraw_request",
            [VLP, TUSD],
            obj(vault_id),
            obj(vault_config),
            obj(lp_obj),
            u64(amount),
            u64(0),
            CLOCK,
        )
        return ptb(label, cmds, expect_abort=expect_abort)

    withdraw_request("withdraw request inside the 20 s lock", lp1_obj, 10_000 * TUSD_UNIT, expect_abort=("vault", 14))

    # The owner trades the vault's account.
    cmds = call(f"{MMV}::interface::create_market_position", [VLP, TUSD, ADMIN], obj(vault_id), obj(vault_admin), obj(vacct["obj"]), obj(ch2))
    cmds += call(
        f"{MMV}::interface::set_position_initial_margin_ratio",
        [VLP, TUSD, ADMIN],
        obj(vault_id),
        obj(vault_admin),
        obj(vacct["obj"]),
        obj(ch2),
        u256(IMR),
    )
    cmds += call(
        f"{MMV}::interface::allocate_collateral_to_position",
        [VLP, TUSD, ADMIN],
        obj(vault_id),
        obj(vault_admin),
        obj(vacct["obj"]),
        obj(ch2),
        u64(5_000 * TUSD_UNIT),
        CLOCK,
    )
    ptb("owner opens the vault's 10x position with 5,000 TUSD", cmds)
    ptb(
        "allocating more than the vault's idle 5,001 TUSD",
        call(
            f"{MMV}::interface::allocate_collateral_to_position",
            [VLP, TUSD, ADMIN],
            obj(vault_id),
            obj(vault_admin),
            obj(vacct["obj"]),
            obj(ch2),
            u64(6_000 * TUSD_UNIT),
            CLOCK,
        ),
        expect_abort=("perpetuals_api", 2),
    )

    def vault_order(label, inner, expect_abort=None):
        cmds = refresh_prices() + no_integrator() + inner
        j = ptb(label, cmds, expect_abort=expect_abort)
        return track(j) if j is not None else None

    j = vault_order(
        "vault market-buys 0.2 BTC",
        call(
            f"{MMV}::interface::place_market_order",
            [VLP, TUSD, ADMIN],
            obj(vault_id),
            obj(vault_admin),
            obj(vacct["obj"]),
            obj(ch2),
            obj(pfs_btc),
            obj(pfs_tusd),
            "false",
            u64(200_000_000),
            "false",
            "no_integrator",
            CLOCK,
            assign="chv",
        )
        + call(f"{PERP}::clearing_house::share", [TUSD], "chv"),
    )
    q10 = fx(100_010) * fx("0.1") // ONE + fx(100_020) * fx("0.1") // ONE
    fee10 = fmul(q10, TAKER_FEE)
    v2 = vault_snap()
    vf = [e for e in events(j, "::events::SettledFunding") if int(e["account_id"]) == vacct["id"]]
    eq("vault long 0.2 BTC", v2["pos"]["VAULT"]["base"], fx("0.2"))
    eq("vault entry 20,003", v2["pos"]["VAULT"]["quote"], q10)
    eq(
        "vault collateral = 5,000 - taker fee 10.0015",
        v2["pos"]["VAULT"]["collateral"],
        (signed(vf[0]["collateral_after"]) if vf else 5_000 * ONE) - fee10,
    )
    eq("vault idle 5,001", v2["acc"]["VAULT"], 5_001 * TUSD_UNIT, fmt=str)
    invariant(v2, "S10 after vault trade")

    j = vault_order(
        "vault rests a 0.1 BTC bid at 99,000",
        call(
            f"{MMV}::interface::place_limit_order",
            [VLP, TUSD, ADMIN],
            obj(vault_id),
            obj(vault_admin),
            obj(vacct["obj"]),
            obj(ch2),
            obj(pfs_btc),
            obj(pfs_tusd),
            "false",
            u64(100_000_000),
            u64(px(99_000)),
            u64(GTC),
            "none",
            "false",
            "none",
            "no_integrator",
            CLOCK,
            assign="r",
        )
        + call(f"{PERP}::clearing_house::share", [TUSD], "r.0"),
    )
    check("vault order resting", list(orders["VAULT"]) == [(BID, px(99_000))])
    vid = orders["VAULT"][(BID, px(99_000))]
    cmds = ["--make-move-vec", "<u128>", f"[{vid}u128]", "--assign", "ids"]
    cmds += call(f"{MMV}::interface::cancel_orders", [VLP, TUSD, ADMIN], obj(vault_id), obj(vault_admin), obj(vacct["obj"]), obj(ch2), "ids", CLOCK)
    track(ptb("vault cancels it", cmds))
    v3 = vault_snap()
    check("vault has no resting orders", not orders["VAULT"] and v3["pos"]["VAULT"]["pending_orders"] == 0)

    # Index +1%: the vault's long is in profit when the next deposit values it.
    btc_price[0] = fx(101_000)
    cmds = refresh_prices()
    cmds += call("0x2::coin::mint", [TUSD], obj(tusd_treasury), u64(5_000 * TUSD_UNIT), assign="c")
    cmds += call(
        f"{MMV}::interface::start_deposit_session",
        [VLP, TUSD],
        obj(vault_id),
        obj(vault_config),
        obj(vacct["obj"]),
        obj(pfs_tusd),
        "c",
        CLOCK,
        assign="ds",
    )
    cmds += call(f"{MMV}::interface::end_deposit_session", [VLP, TUSD], "ds", obj(vault_config), u64(0), obj(registry), assign="lp")
    cmds += ["--transfer-objects", "[lp]", obj(me)]
    ptb("deposit that skips valuing the vault's market", cmds, expect_abort=("vault", 17))

    pre2 = vault_snap()
    j = deposit("user deposits 5,000 TUSD with the vault in profit", 5_000 * TUSD_UNIT, process=[ch2])
    minted += 5_000 * TUSD_UNIT
    t_dep2 = time.time()
    ud = events(j, "::events::UserDeposit")[0]
    lp2_obj = owned_created(j, "::vault::UserLpCoin<")
    vbv = signed(ud["vault_balance_value"])
    P2 = pre2["pos"]["VAULT"]
    est = pre2["acc"]["VAULT"] * FIXED_PER_TUSD_UNIT + P2["collateral"] + P2["funding"] + fmul(P2["base"], fx(101_000)) - P2["quote"]
    check("vault valued near idle + margin at the 101,000 index", abs(vbv - est) <= fx(25), f"{usd(vbv)} vs {usd(est)}")
    want_lp, want_taken = lp_for(5_000 * TUSD_UNIT, pre2["lp_supply"], vbv)
    lp2_provided = want_taken * FIXED_PER_TUSD_UNIT
    eq("LP minted = supply * 5,000 / vault value", int(ud["lp_coin_minted"]), want_lp, fmt=str)
    check("fewer LP than TUSD now that LP is worth more", want_lp < 5_000 * TUSD_UNIT, f"{want_lp}")
    eq("deposit taken after LP rounding", int(ud["provided_balance"]), want_taken, fmt=str)
    v4 = vault_snap([lp1_obj, lp2_obj])
    eq("LP supply grew by the minted amount", v4["lp_supply"], pre2["lp_supply"] + want_lp, fmt=str)

    # Free idle cash for the coming withdrawal.
    cmds = refresh_prices() + call(
        f"{MMV}::interface::deallocate_collateral_from_position",
        [VLP, TUSD, ADMIN],
        obj(vault_id),
        obj(vault_admin),
        obj(vacct["obj"]),
        obj(ch2),
        obj(pfs_btc),
        obj(pfs_tusd),
        f"some({2_000 * TUSD_UNIT}u64)",
        CLOCK,
    )
    ptb("owner deallocates 2,000 TUSD to the vault's idle cash", cmds)

    wait = t_dep1 + LOCK_MS / 1000 + 2 - time.time()
    if wait > 0:
        print(f"  waiting {wait:.0f} s for the first deposit's lock period")
        time.sleep(wait)
    j = withdraw_request("user requests to withdraw the first 10,000 LP", lp1_obj, 10_000 * TUSD_UNIT)
    check("withdraw request created", len(events(j, "::events::UserCreateWithdrawRequest")) == 1)
    withdraw_request("a second request from the same address", lp2_obj, want_lp, expect_abort=("vault", 28))
    # The session is closed in the same PTB: an unconsumed WithdrawSession would be rejected
    # (UnusedValueWithoutDrop) before any Move code runs, hiding the delay check.
    cmds = refresh_prices() + call(
        f"{MMV}::interface::start_force_withdraw_session",
        [VLP, TUSD],
        obj(vault_id),
        obj(vacct["obj"]),
        obj(pfs_tusd),
        CLOCK,
        assign="fw",
    )
    cmds += call(f"{MMV}::interface::end_withdraw_session_and_transfer_to_recipient", [VLP, TUSD], "fw", obj(vault_config), obj(registry))
    ptb("force withdraw before the 10 s delay", cmds, expect_abort=("vault", 5))

    def owner_process(label, with_market):
        cmds = refresh_prices()
        cmds += call(
            f"{MMV}::interface::start_owner_process_withdraw_request",
            [VLP, TUSD, ADMIN],
            obj(vault_id),
            obj(vault_admin),
            obj(vacct["obj"]),
            obj(pfs_tusd),
            obj(me),
            CLOCK,
            assign="ws",
        )
        if with_market:
            cmds += call(
                f"{MMV}::interface::process_clearing_house_for_withdraw",
                [VLP, TUSD, ADMIN],
                "ws",
                obj(vault_admin),
                obj(ch2),
                obj(pfs_btc),
                CLOCK,
            )
        cmds += call(f"{MMV}::interface::end_withdraw_session_and_transfer_to_recipient", [VLP, TUSD], "ws", obj(vault_config), obj(registry))
        return ptb(label, cmds)

    def expected_withdraw(idle_units, vbv, lp, supply, provided):
        vault_value = idle_units * FIXED_PER_TUSD_UNIT + vbv
        value = fdiv(fmul(lp * B9, vault_value), supply * B9)
        amount = value // FIXED_PER_TUSD_UNIT
        fee = fmul(value - provided, OWNER_FEE) // FIXED_PER_TUSD_UNIT if value > provided else 0
        return value, amount, fee

    pre3 = vault_snap([lp2_obj])
    j = owner_process("owner processes the 10,000 LP withdrawal", with_market=True)
    ow = events(j, "::events::OwnerWithdraw")[0]
    value1, amount1, fee1 = expected_withdraw(pre3["acc"]["VAULT"], signed(ow["vault_balance_value"]), 10_000 * TUSD_UNIT, pre3["lp_supply"], 10_000 * ONE)
    check("user's share grew with the vault's profit", value1 > 10_000 * ONE, usd(value1))
    check("owner fee charged on the profit only", fee1 > 0, f"{fee1 / TUSD_UNIT:.6f} TUSD")
    eq("user receives share - 10% of profit", int(ow["withdrawn_balance"]), amount1 - fee1, fmt=str)
    v5 = vault_snap([lp2_obj])
    eq("vault idle cash -= share", v5["acc"]["VAULT"], pre3["acc"]["VAULT"] - amount1, fmt=str)
    eq("10,000 LP burned", v5["lp_supply"], pre3["lp_supply"] - 10_000 * TUSD_UNIT, fmt=str)

    ptb(
        "treasury withdraws one unit more than the owner fees",
        call(f"{MMV}::interface::withdraw_fees", [VLP, TUSD], obj(vault_id), obj(vault_treasury), u64(fee1 + 1), assign="f")
        + ["--transfer-objects", "[f]", obj(me)],
        expect_abort=("vault", 33),
    )
    ptb(
        "treasury withdraws the owner fees",
        call(f"{MMV}::interface::withdraw_fees", [VLP, TUSD], obj(vault_id), obj(vault_treasury), u64(fee1), assign="f")
        + ["--transfer-objects", "[f]", obj(me)],
    )

    j = ptb(
        "package admin creates a vault pause guardian",
        call(f"{MMV}::interface::create_package_pause_guardian_cap", [], obj(vault_config), obj(vault_pkg_admin), assign="pg")
        + ["--transfer-objects", "[pg]", obj(me)],
    )
    vault_pauser = owned_created(j, f"{MMV}::authority::PAUSE_GUARDIAN>")
    ptb("pause the vault", call(f"{MMV}::interface::admin_pause_vault", [VLP, TUSD], obj(vault_id), obj(vault_pauser), obj(vault_config)))
    deposit("deposit into a paused vault", 10 * TUSD_UNIT, process=[ch2], expect_abort=("vault", 15))
    ptb("unpause the vault", call(f"{MMV}::interface::admin_unpause_vault", [VLP, TUSD], obj(vault_id), obj(vault_pauser), obj(vault_config)))

    # Close the position, return everything to cash and pay out the second depositor.
    j = vault_order(
        "vault closes its long (reduce-only sell 0.2)",
        call(
            f"{MMV}::interface::place_market_order",
            [VLP, TUSD, ADMIN],
            obj(vault_id),
            obj(vault_admin),
            obj(vacct["obj"]),
            obj(ch2),
            obj(pfs_btc),
            obj(pfs_tusd),
            "true",
            u64(200_000_000),
            "true",
            "no_integrator",
            CLOCK,
            assign="chv",
        )
        + call(f"{PERP}::clearing_house::share", [TUSD], "chv"),
    )
    ft = events(j, "::events::FilledTakerOrder")[0]
    q_close = fx(99_990) * fx("0.1") // ONE + fx(99_980) * fx("0.1") // ONE
    eq("vault realized pnl 19,997 - 20,003 = -6", signed(ft["taker_pnl"]), q_close - q10)
    cmds = refresh_prices() + call(
        f"{MMV}::interface::deallocate_collateral_from_position",
        [VLP, TUSD, ADMIN],
        obj(vault_id),
        obj(vault_admin),
        obj(vacct["obj"]),
        obj(ch2),
        obj(pfs_btc),
        obj(pfs_tusd),
        "none",
        CLOCK,
    )
    ptb("owner returns all free collateral to cash", cmds)
    v6 = vault_snap([lp2_obj])
    check("vault position flat with dust at most", v6["pos"]["VAULT"]["base"] == 0 and v6["pos"]["VAULT"]["collateral"] < FIXED_PER_TUSD_UNIT)

    wait = t_dep2 + LOCK_MS / 1000 + 2 - time.time()
    if wait > 0:
        print(f"  waiting {wait:.0f} s for the second deposit's lock period")
        time.sleep(wait)
    withdraw_request("user requests to withdraw the second deposit", lp2_obj, v6["user_lp"][0])
    pre4 = vault_snap()
    j = owner_process("owner processes it with no market left to value", with_market=False)
    ow = events(j, "::events::OwnerWithdraw")[0]
    eq("no clearing house counted", signed(ow["vault_balance_value"]), 0)
    value2, amount2, fee2 = expected_withdraw(pre4["acc"]["VAULT"], 0, v6["user_lp"][0], pre4["lp_supply"], lp2_provided)
    eq("second depositor receives their share", int(ow["withdrawn_balance"]), amount2 - fee2, fmt=str)
    v7 = vault_snap()
    eq("only the owner-locked LP is left", v7["lp_supply"], TUSD_UNIT, fmt=str)
    check("owner's locked LP is still backed by cash", v7["acc"]["VAULT"] > 0, f"{v7['acc']['VAULT'] / TUSD_UNIT:.6f} TUSD")
    invariant(v7, "S10 end")

    # Every TUSD ever minted is accounted for.
    s_end1 = snapshot(with_mark=False)
    s_end2 = vault_snap(with_mark=False)
    bal = json.loads(cli("client", "balance", "--coin-type", TUSD, "--json").stdout)
    wallet = _wallet_total(bal)
    total = (
        wallet
        + sum(s_end1["acc"].values())
        + s_end2["acc"]["VAULT"]
        + s_end1["market"]["vault"]
        + s_end1["market"]["insurance"]
        + s_end2["market"]["vault"]
        + s_end2["market"]["insurance"]
    )
    eq("TUSD conserved across both markets and the vault", total, minted, fmt=str)

    # ------------------------------------------------------------ summary
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} checks passed")
    return 0 if passed == len(RESULTS) else 1


def _wallet_total(bal):
    """Sum of the `balance` entries in `haneul client balance --coin-type T --json`."""
    total = 0

    def walk(x):
        nonlocal total
        if isinstance(x, dict):
            inner = x.get("balance")
            if isinstance(inner, dict) and "coinBalance" in inner:
                total += int(inner["balance"])
                return
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(bal)
    return total


if __name__ == "__main__":
    try:
        sys.exit(main())
    except E2EError as e:
        print(f"\nE2E ERROR: {e}")
        passed = sum(1 for _, ok in RESULTS if ok)
        print(f"{passed}/{len(RESULTS)} checks passed before the error")
        sys.exit(2)
