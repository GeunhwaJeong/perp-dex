# Deployment packages

Packages that belong to a deployment of the engine rather than to the engine itself.

| Package | Modules | Purpose |
|---|---|---|
| `sigma_support` | tusd, vendor_key, vlp | What the Sigma deployment on Haneul mainnet needs beside the engine: the shadow run's test collateral `TUSD` (6 decimals, treasury to the publisher), the vendor key type `SIGMA` that Sigma registers with `vendor`, `oracle_aggregator` and `perpetuals`, and the vault LP coin `VLP`. The localnet suite's `e2e/perp_e2e` plays the same role on a local network, with its probes on top. |

Publish with the deployment's admin key before the engine's vendor registration; the vendor key
type's address goes into every registration call, and the coin type into the deployment file.

```bash
cd deploy/sigma_support
haneul move build --build-env mainnet
```
