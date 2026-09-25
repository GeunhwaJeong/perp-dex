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
| `perpetuals` | account, adl, authority, clearing_house, events, init, keys, market, orderbook, registry, stop_orders, twap_orders | Clearing house, order book, markets, accounts, stop and TWAP orders, liquidation, ADL | vendor, ifixed, authority_cap, position, oracle_aggregator, ordered_map |
| `market_making_vault` | authority, config, errors, events, init, interface, keys, metadata, perpetuals_api, vault | LP vaults: deposits, withdrawal requests, trading sessions run by the vault owner | perpetuals and six others |

Publish order: `ifixed`, `authority_cap`, `ordered_map`, `af_lp`, then `position`, `vendor`, then
`oracle_aggregator`, then `oracle_pyth`, `perpetuals`, then `market_making_vault`.

## Dependencies

All dependencies are local paths, so the packages build offline:

- `deps/haneul-src/crates/haneul-framework/packages/`: the `haneul-framework` and `move-stdlib`
  packages from the Haneul repository at commit `7d11581` (workspace 1.12.0, protocol 127).
- `deps/haneul-oracle/`: the Pyth (`0x9998fae7...`) and Wormhole (`0xcd66f333...`) packages as
  published on Haneul mainnet, used by `oracle_pyth`.

## Build

With the Haneul CLI 1.12.0 or later:

```bash
cd packages/perpetuals
haneul move build --build-env mainnet
```

Every package builds without warnings.

## Unit tests

Six packages carry Move unit tests under their `tests/` directories, 255 in total:

| Package | Tests | What is checked |
|---|---|---|
| `ifixed` | 32 | Every arithmetic variant against a sign-and-magnitude reference, on edge values and pseudo-random operands, including rounding directions and overflow aborts |
| `ordered_map` | 21 | The B+ tree against a sorted vector under insert, remove, try-remove, clear and batch-drop sequences with the smallest node parameters |
| `position` | 34 | Fills on both sides with their rounding, taker settlement, funding, free collateral, maker fill restoration, margin requirement checks, bankruptcy price |
| `oracle_pyth` | 14 | Exponent scaling of Pyth prices to 18 decimals, feed creation from a Pyth price object with its millisecond timestamp, the feed's binding to that object, source authorization and versioning, feed administration |
| `market_making_vault` | 25 | LP pricing on cash and on margin, the withdraw request lifecycle, owner-processed withdrawals with the owner fee and treasury, and forced withdrawals: delay, cash-only, closing the position for a dominant share, the partial-close margin band for a small share, order cancelation, and the force-withdraw pause window |
| `perpetuals` | 129 | The order book alone (18); matching, order types, validation, self-trade, expiry, reduce-only, margin and collateral flows (38); liquidation, bad debt, socialization and ADL (13); pausing, close and settlement, treasury, proposals, freezing (17); stop loss / take profit and standalone stop tickets (23); TWAP tickets (20) |

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
Haneul mainnet. A full run takes about four minutes and ends with `209/209 checks passed`.

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

In total 28 of the checks are actions that must be rejected with a specific abort code. After every
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
`perpetuals`, `oracle_pyth` and `market_making_vault`; the aggregator, vendor and the small
`authority_cap` and `af_lp` packages are only exercised by the localnet suite.

## License

Each source file carries its own SPDX license identifier.
