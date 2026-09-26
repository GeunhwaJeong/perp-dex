# Haneul Perpetuals

An on-chain perpetual futures exchange for Haneul, written in Haneul Move. Each market is a
clearing house with its own central limit order book. Prices come from an oracle aggregator that
Pyth feeds through an adapter, and market-making vaults let depositors provide liquidity through a
managed trading account.

None of the packages are published yet; every package address is `0x0`.

## Packages

| Package | Modules | Purpose | Depends on |
|---|---|---|---|
| `ifixed` | ifixed | Signed 18-decimal fixed point (two's complement `u256`) | |
| `authority_cap` | authority | Role-based authority caps (admin, assistant, ...) with revocation | |
| `ordered_map` | enum_option, ordered_map | B+tree ordered map that stores the order book | |
| `af_lp` | af_lp | LP coin type | |
| `position` | position | Position accounting: fills, funding settlement, bad debt | ifixed |
| `vendor` | authority, config, events, init, metadata | Registration and metadata of the vendors that operate markets and price feeds | authority_cap |
| `oracle_aggregator` | authority, config, events, init, price, price_feed, price_feed_storage, source | Price feed storage; newest, median and TWAP prices across sources | vendor, authority_cap |
| `oracle_pyth` | init, price_feed_storage, source | Adapter that writes Pyth prices into `oracle_aggregator` feeds | the above, Pyth |
| `perpetuals` | account, adl, authority, clearing_house, events, init, keys, market, orderbook, registry | Clearing house, order book, markets, accounts, liquidation, ADL, and the extension gate other packages drive sessions through | vendor, ifixed, authority_cap, position, oracle_aggregator, ordered_map |
| `perpetuals_orders` | events, extension, stop_orders, twap_orders | Stop loss / take profit, standalone stop and TWAP order tickets, executed through the perpetuals extension gate with the `ORDERS` witness | perpetuals, authority_cap, oracle_aggregator, ifixed |
| `staking_tiers` | registry | Holds deposited `StakedHaneul` objects and grades each address by active principal, with a withdrawal delay; a chain-wide staking tier any package can read | haneul_system |
| `perpetuals_fees` | config, extension, fees, volume | Fee tiers: a schedule of volume tiers and staking discounts, a per-account rolling taker volume window, and the fee multipliers cached on each market through the extension gate with the `FEES` witness | perpetuals, staking_tiers, authority_cap, ifixed |
| `market_making_vault` | authority, config, errors, events, init, interface, keys, metadata, perpetuals_api, vault | LP vaults: deposits, withdrawal requests, trading sessions run by the vault owner | perpetuals, perpetuals_orders and six others |

Publish order: `ifixed`, `authority_cap`, `ordered_map`, `af_lp`, then `position`, `vendor`, then
`oracle_aggregator`, then `oracle_pyth`, `perpetuals`, `perpetuals_orders`, `staking_tiers`,
`perpetuals_fees`, then `market_making_vault`.
After publishing, the perpetuals package admin authorizes the extension witnesses with
`registry::authorize_extension<perpetuals_orders::extension::ORDERS>` and
`registry::authorize_extension<perpetuals_fees::extension::FEES>`; the localnet suite does this
in its setup.

## Fee tiers

The core charges each market's own maker and taker rates. `perpetuals_fees` discounts them per
account: ending a session through `fees::end_session` records the session's taker notional in a
rolling window of epochs kept on the account, looks up the sender's active stake in the
`staking_tiers` registry, and caches the resulting (taker, maker) multipliers on the market with
`clearing_house::set_fee_multiplier_as_extension`. The next sessions on that market, as taker or as
maker, are charged the market rate times the multiplier until the cache expires; `fees::refresh`
caches without trading. Multipliers are ifixed fractions in [0, 1], so an extension can only ever
discount, and a market-level maker rebate stays covered by the discounted taker fee.

The schedule (`config::set_schedule`) lists volume tiers as absolute rates against reference base
rates and staking tiers as a discount on top; both are shaped like Hyperliquid's table and every
value is an admin setting. Volume counts taker fills only in this version; maker volume and
maker-share rebates need a hook in the maker fill path and are left for a later change.

Staking is native: an address deposits its `StakedHaneul` objects into the registry, keeps
earning validator rewards on them, and counts their principal toward its tier at once. Leaving
takes a withdrawal request and the registry's delay (seven days by default), during which the
principal no longer counts.

## Dependencies

All dependencies are local paths, so the packages build offline:

- `deps/haneul-src/crates/haneul-framework/packages/`: the `haneul-framework`, `move-stdlib` and
  `haneul-system` packages from the Haneul repository at commit `7d11581` (workspace 1.12.0,
  protocol 127). The system package's `tests/` directory is included because `staking_tiers`
  tests build on its `test_runner`.
- `deps/haneul-oracle/`: the Pyth (`0x9998fae7...`) and Wormhole (`0xcd66f333...`) packages as
  published on Haneul mainnet, used by `oracle_pyth`.

## Build

With the Haneul CLI 1.12.0 or later:

```bash
cd packages/perpetuals
haneul move build --build-env mainnet
```

Every package builds without warnings.

## Package size

The chain limits a published package object to 100 KiB (`max_move_package_size`, 102,400
bytes), and the object carries about 6.7 KB of type origin and linkage tables on top of the
module bytecode, so a package's modules must stay below roughly 95 KB. `perpetuals` was at that
line, which is why the stop and TWAP orders live in `perpetuals_orders` (15.8 KB) and drive the
clearing house through the extension gate; `perpetuals` is now at 81.1 KB. Measure after
building:

```bash
cd packages/perpetuals && haneul move build --build-env mainnet && \
  ls -l build/perpetuals/bytecode_modules/*.mv | awk '{s+=$5} END {print s}'
```

A publish that fails with `MovePackageTooBig` means this budget was exceeded; function names are
stored in every module that calls them, so long identifiers and duplicated code both count. The
same gate (`registry::authorize_extension`, the `*_as_extension` entry points of `clearing_house`
and `account`) is how further features can live in packages of their own.

## Unit tests

Nine packages carry Move unit tests under their `tests/` directories, 284 in total:

| Package | Tests | What is checked |
|---|---|---|
| `ifixed` | 32 | Every arithmetic variant against a sign-and-magnitude reference, on edge values and pseudo-random operands, including rounding directions and overflow aborts |
| `ordered_map` | 21 | The B+ tree against a sorted vector under insert, remove, try-remove, clear and batch-drop sequences with the smallest node parameters |
| `position` | 34 | Fills on both sides with their rounding, taker settlement, funding, free collateral, maker fill restoration, margin requirement checks, bankruptcy price |
| `oracle_pyth` | 14 | Exponent scaling of Pyth prices to 18 decimals, feed creation from a Pyth price object with its millisecond timestamp, the feed's binding to that object, source authorization and versioning, feed administration |
| `market_making_vault` | 25 | LP pricing on cash and on margin, the withdraw request lifecycle, owner-processed withdrawals with the owner fee and treasury, and forced withdrawals: delay, cash-only, closing the position for a dominant share, the partial-close margin band for a small share, order cancelation, and the force-withdraw pause window |
| `perpetuals` | 92 | The order book alone (18); matching, order types, validation, self-trade, expiry, reduce-only, margin and collateral flows (38); liquidation, bad debt, socialization and ADL (13); pausing, close and settlement, treasury, proposals, freezing, registry configuration and the extension gate (23) |
| `perpetuals_orders` | 43 | Stop loss / take profit and standalone stop tickets (23); TWAP tickets (20) |
| `staking_tiers` | 9 | Deposits on a `test_runner` system state with a real validator, tier thresholds, the withdrawal request, delay, cancel and withdraw paths, and owner and admin checks |
| `perpetuals_fees` | 14 | The volume window (2); schedule validation and multiplier math (4); sessions on the perpetuals fixture: volume recording, the cached tier on the next session, the staking discount, the maker-side multiplier, expiry, and the core's authorization and bound checks (8) |

The perpetuals tests run on a `test_scenario` fixture (`tests/test_support.move`) that stands up
the vendor, oracle and perpetuals packages, a mock price source and one BTC/USD market with the
localnet suite's parameters; the vault tests add a vault over that market.

```bash
cd packages/perpetuals && haneul move test --build-env mainnet
```

## Localnet end-to-end tests

`e2e/localnet_e2e.py` publishes all ten packages together with the `e2e/perp_e2e` helper package to
a local network and drives the engine through real transactions. The helper package provides a
test collateral coin (TUSD, 6 decimals), a vault LP coin (VLP), an oracle source whose prices the
test sets by hand, and read-only probes. Engine state is read by simulating the probes over gRPC.

Requirements: the Haneul CLI, `python3` and `grpcurl`.

```bash
haneul start --with-faucet --force-regenesis
haneul client switch --env local
haneul client faucet
python3 e2e/localnet_e2e.py
```

The script uses `deps/bin/haneul` when it exists and `haneul` on `PATH` otherwise; set `HANEUL` to
use another binary. It refuses to run unless the active environment is local and the chain is not
Haneul mainnet. A full run takes about four minutes and ends with `229/229 checks passed`.

| Scenario | What is checked |
|---|---|
| Setup | Vendor, oracle and market registration; four accounts funded |
| S1 | A 12-order maker ladder: best prices, pending sizes, order counts |
| S2 | Leverage opt-in, a market buy across three price levels, taker and maker fees |
| S3 | A limit order that fills partially and rests the remainder |
| S4 | 13 rejected actions (post-only, fill-or-kill, tick and lot sizes, margin, stale oracle, foreign caps, ...) leave state unchanged |
| S5 | Cancels, including a rejected cancel of another account's order |
| S6 | Price move, maker requote, a reduce-only close with realized profit, collateral withdrawal |
| S7 | Partial liquidation, recomputed independently in the script |
| S8 | Fee withdrawal, insurance fund donation, market pause and resume |
| S9 | Market close, settlement of every position, conservation of TUSD |
| S10 | Market-making vault: creation, deposits and LP pricing, trading through the vault, lock period, withdrawal with owner fee, pause |
| S11 | Fee tiers: the schedule and staking thresholds, a session ended through `perpetuals_fees` that records volume and caches a multiplier, a real `StakedHaneul` deposited into the tier registry, the 40% staking discount on the next fill, the second volume tier, the withdrawal request dropping the tier, the early withdrawal rejected, and the cancel |

In total 29 of the checks are actions that must be rejected with a specific abort code. After every
step the script also checks that each market's collateral equals the sum of position equity at entry
prices plus accrued fees.

Stop and TWAP orders, the Pyth adapter (Pyth and Wormhole are not on a fresh localnet) and the
vault's forced-withdrawal path are covered by unit tests rather than by this suite.

## Operational notes

See `docs/market-launch.md` for the launch order and the operators a market depends on.

- `create_clearing_house` takes a `market::MarketCreationParams` built with
  `new_creation_params` (margin ratios, lot and tick size, bad debt policy) and the `set_*`
  setters. The bad debt policy is explicit: `max_bad_debt` and `max_socialize_losses_mr_decrease`
  bound what a liquidation may socialize once the insurance fund is exhausted, and zeros turn
  socialization off, which makes an ADL operator mandatory for that market.
- A new position starts with an initial margin ratio of 1.0, i.e. no leverage. Set the leverage with
  `clearing_house::set_position_initial_margin_ratio`, at or above the market's ratio.
- A vault's LP coin must have the same decimals as its collateral, and the owner's locked
  liquidity must be worth between $0.95 and $2.
- Vault withdrawals are paid from the vault account's idle collateral, so the owner deallocates
  from markets before processing large withdrawals.

## Status

The packages are not published. Unit tests cover `ifixed`, `ordered_map`, `position`,
`perpetuals`, `perpetuals_orders`, `staking_tiers`, `perpetuals_fees`, `oracle_pyth` and
`market_making_vault`; the aggregator, vendor and the small `authority_cap` and `af_lp` packages
are only exercised by the localnet suite.

## License

Each source file carries its own SPDX license identifier.
