# Market launch runbook

What has to happen, in order, before a clearing house takes its first order, and what has to be
running afterwards. Every step names the Move entry point; the localnet suite
(`e2e/localnet_e2e.py`) performs the same steps and is the reference for the exact arguments.

## 1. Package configuration (once per deployment)

The registry holds the bounds every market is validated against, changed through a
`registry::ConfigUpdate` (`new_config_update`, the `set_*` setters, `apply_config_update`): fee caps, funding and
TWAP bounds, proposal delays, minimum order value range, the insurance reserve fraction, the
oracle tolerance floor, and the pending order and assistant caps. Review them before the first
market; the defaults are conservative but not tuned for any particular asset.

Authorize the extension packages once with the package admin cap:
`registry::authorize_extension<perpetuals_orders::extension::ORDERS>` for conditional orders and
`registry::authorize_extension<perpetuals_fees::extension::FEES>` for fee tiers. Stop and TWAP
tickets cannot be created or executed, and fee multipliers cannot be cached, until this is done;
`deauthorize_extension` switches either off again.

Then set the fee schedule (`perpetuals_fees::config::set_schedule` with the schedule admin cap):
the reference base rates, the volume tiers as absolute rates at or below the base, the staking
tiers as discounts, the maker-share tiers (a negative maker fee is a rebate, bounded by the
smallest taker rate, each with a floor of the maker's own volume on the market so that the sole
maker of a new market earns nothing until real volume stands behind its share), the multiplier
lifetime and the volume window in epochs. Set the staking tier
thresholds and withdrawal delay on the `staking_tiers` registry (`registry::set_thresholds`,
`registry::set_withdraw_delay_ms`). Markets whose rates differ from the base rates are discounted
in proportion.

Caps to mint from the package admin cap, each to a separate operator key:

| Cap | Entry point | Used by |
|---|---|---|
| ADL | `registry::create_package_adl_cap` | The ADL operator (`adl::execute_adl`) |
| Pause guardian | `registry::create_package_pause_guardian_cap` | Emergency pause of any market |
| Freeze guardian | `registry::create_package_freeze_guardian_cap` | Freezing the registry or a market |
| Revoke vendor guardian | `registry::create_package_revoke_vendor_guardian_cap` | Revoking a vendor's caps |

## 2. Vendor registration

The vendor key is a type in a package the vendor controls. Register it with the vendor package
(`vendor::config::register_vendor`), create its metadata, approve the oracle and perpetuals
domains on that metadata, then register with `oracle_aggregator::config::register_vendor` and
`perpetuals::registry::register_vendor`. From the perpetuals vendor admin cap mint the treasury,
pause guardian and maintenance caps (`registry::create_vendor_*_cap`).

## 3. Oracle feeds

Create one `PriceFeedStorage` per priced asset (`price_feed_storage::new`) and add the Pyth feed
to each through `oracle_pyth::price_feed_storage::new_price_feed`. The market needs one storage
for the base asset and one for the collateral, both with the source id it will be created with.
A price pusher must keep the feeds fresher than the market's oracle tolerance (10 s for the base
feed and 30 s for the collateral by default) or every session aborts with `EBadIndexPrice`.

## 4. Market creation

`clearing_house::create_orderbook`, then the creation parameters, then
`clearing_house::create_clearing_house` (or `create_clearing_house_with_currency`),
`register_market`, `share`.

The creation parameters are a builder in the same transaction: `market::new_creation_params`
takes the six values with no safe default (initial and maintenance margin ratios, lot and tick
size, `max_bad_debt`, `max_socialize_losses_mr_decrease`), and `set_fees`, `set_funding`,
`set_premium_twap`, `set_spread_twap` and `set_priority_taker_fee` fill in the rest. Until set,
fees are zero, funding runs every minute over six hours, both TWAPs sample every second over a
minute, and the priority taker fee is `none`. Each setter is a separate call, so the order of
same-typed arguments can no longer be swapped silently.

Parameters that decide how the market behaves under stress:

- **`max_bad_debt` and `max_socialize_losses_mr_decrease`.** When a liquidation leaves bad debt
  that the insurance fund cannot cover, the rest is socialized to the other side of the market
  through its cumulative funding rate, bounded by these two values (USD per liquidation, and
  the margin ratio drop it may cause). With both at zero, socialization is off: such a
  liquidation aborts and the position must be closed by the ADL operator. **A market created
  with zeros needs a running ADL operator; a market with no ADL operator needs non-zero limits
  and a funded insurance fund.**
- **`priority_taker_fee`.** The extra taker fee for sessions paying above the reference gas
  price, or `none` (the default) to refuse them.
- **Margin ratios, fees, lot and tick size.** Changing margin ratios later takes a one to three
  day proposal (`create_margin_ratios_proposal`, `commit_margin_ratios_proposal`); the rest is
  immediate through `set_fee_params` and `set_core_params`.

Not passed at creation and worth setting explicitly right after with `set_risk_limit_params`:
`max_open_interest` (unbounded by default), `max_open_interest_threshold` and
`max_open_interest_position_percent` (20% above the threshold), `min_order_usd_value` (the
registry's floor), `max_pending_orders` (the registry's cap), `max_book_index_spread` and
`max_index_twap_divergence` (5%).

## 5. Insurance fund

Seed it with `clearing_house::donate_to_insurance_fund` before opening. Withdrawals keep a
reserve of `insurance_open_interest_fraction` times the open interest notional (5% by default).
Liquidations add the insurance fee share of every liquidated notional to it.

## 6. Off-chain operators that must be running

| Operator | Calls | Why |
|---|---|---|
| Price pusher | `oracle_pyth::price_feed_storage::update_price_feed` | Freshness within the tolerance |
| Funding cranker | `clearing_house::update_funding` | Funding and premium TWAPs only advance when something touches the market |
| Liquidator | `liquidate` inside a session | Positions below the maintenance margin |
| ADL operator | `adl::execute_adl` | Negative-equity positions when socialization is off or exhausted |
| Stale order sweeper (optional) | `try_cancel_stale_orders` with the maintenance cap | Expired and no-longer-reducing reduce-only orders |
| Stop and TWAP executors | `perpetuals_orders::stop_orders::place_stop_order_*`, `perpetuals_orders::twap_orders::execute` | Conditional orders are executed by whoever the ticket names |
| Fee tier front end (no operator) | `perpetuals_fees::fees::end_session` in place of `clearing_house::end_session`, `fees::refresh` after staking or making, `fees::set_tier_address` once per account | Volume is only recorded and multipliers only cached through these calls; a maker's credited volume reaches its tier on its next session or refresh on that market; a session ended through the core pays the market rate. The staking discount follows the account's tier address, which the owner registers with its admin cap (it is always the signer), so sessions signed by assistant keys keep it; without one each session is priced by its signer |

Two calculations the operators must get right:

- **TWAP executor.** An unfilled remainder of an earlier chunk is only retried when the
  `amount` passed to `execute` is smaller than the chunk, since the retry fills the gap up to
  the per-run maximum. With `amount_uncertainty_bps` at zero the amount must equal the chunk
  exactly and nothing is ever retried; give orders a non-zero uncertainty and, once
  `unfilled_scheduled_amount` is positive, pass a reduced amount (down to zero) to retry it.
- **Force-withdraw executor.** `size_to_close` frees the withdrawer's share of that market's
  margin only, not of the whole vault; the rest is paid from the vault's idle collateral at
  settlement. Compute the share of the market margin (`lp / lp_supply` times the position's
  margin at the mark), then the smallest lot-rounded close that leaves the remaining position
  at the target margin ratio after that share is deallocated. Too little aborts with
  `EForceWithdrawBelowMarginRatio` (9), too much with
  `EForceWithdrawAboveMarginRatioTolerance` (13), and a share too small to justify a full close
  with `EForceWithdrawCollateralLeftover` (47). Positions worth $5 or less are always closed
  in full.

## 7. Opening checklist

- Both feeds fresh, TWAP window set (`set_twap_period_ms`).
- `set_risk_limit_params` applied; `max_open_interest` set.
- Insurance fund seeded.
- Bad debt policy decided and consistent with the operators running (step 4).
- Pause and freeze guardian keys reachable by someone on call.
- Accounts opt into leverage explicitly (`set_position_initial_margin_ratio`); new positions
  start at 1.0.
