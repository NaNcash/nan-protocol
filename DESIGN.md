# NaN protocol design

NaN divides one pooled wstETH reserve into a senior stable claim and a junior residual claim. It is inspired by the senior/junior reserve idea explored by USM/FUM, but this repository is a clean-room implementation with a simpler immutable state machine.

## Accounting

All USD values use 18 decimals. The collateral token must also use 18 decimals.

```text
R = oracle USD value of reserve wstETH
D = NaN total supply
E = max(R - D, 0)
S = active INF total supply

INF NAV = E / S
```

One NaN represents one dollar of senior debt while the reserve is solvent. wstETH staking rewards increase `R` without increasing `D`, so they accrue entirely to INF.

All conversions round down in favor of the reserve. The minimum reserve used by the debt-ratio limit rounds up.

## States

| State | Definition | Consequence |
| --- | --- | --- |
| No debt | `D == 0` | INF owns the reserve |
| Healthy | `R > D` and `D / R <= maxDebtRatio` | All ordinary operations available |
| Stressed | `R > D` and `D / R > maxDebtRatio` | Funding and redemption available; mint/defund remain constrained |
| Insolvent | `R <= D` | NaN redeems pro rata; INF NAV is zero; recapitalization available |

## State transitions

### Fund

Funding deposits wstETH and mints INF at the current residual NAV. The initial INF series bootstraps at $1. Funding at zero equity is disabled because any ordinary NAV formula would transfer value from the recapitalizer to underwater junior holders.

### Mint

```text
usdIn = collateralIn * oraclePrice
fee = usdIn * mintFee
NaN out = usdIn - fee
```

All collateral, including the fee value, stays in the reserve. The transaction must leave `D / R` at or below the immutable maximum.

### Defund

INF burns for its proportional residual value. The conversion rounds down, and the post-withdrawal reserve must still satisfy the maximum debt ratio. When there is no NaN debt, all INF can redeem the full reserve.

### Redeem

When `R > D`, NaN redeems at $1 less the redemption fee. The retained fee increases INF NAV and redemption improves the collateral ratio.

When `R <= D`, the explicit fee is disabled and the gross redemption price is:

```text
NaN redemption price = R / D
```

This preserves the reserve/debt ratio across redemptions, apart from conservative rounding. The final insolvent redeemer receives all remaining collateral so rounding dust cannot become trapped.

### Recapitalize

At zero junior equity, a recapitalizer must deposit more value than the senior shortfall:

```text
shortfall = D - R
new INF out = usdIn - shortfall
```

The old INF contract is retired atomically and a new OpenZeppelin-based INF contract becomes active. The new series starts with NAV of $1; the recapitalizer explicitly bears the old senior shortfall. This is a wipeout model, not an auction. Applications must follow `inf()`, `juniorSeries`, and `Recapitalized` rather than assuming INF has a permanent address.

If the last insolvent NaN redemption exhausts both debt and collateral, `recapitalize` can similarly retire the worthless INF series and restart the system without a senior shortfall.

## Oracle

The oracle uses three inputs:

```text
effective stETH/ETH = min(1, market stETH/ETH)
wstETH/ETH = stEthPerToken() * effective stETH/ETH
wstETH/USD = wstETH/ETH * ETH/USD
```

The ETH/USD and stETH/ETH feeds are Chainlink-compatible and independently checked for positive answers, timestamps, staleness, and round completion. Capping stETH at 1 ETH prevents a market premium from inflating collateral value; using the market rate below 1 ETH protects the reserve during a depeg. A production deployment must validate feed liquidity, heartbeat, deviation thresholds, and network-specific failure modes.

## Immutability and trust model

The reserve has no owner and no upgrade path. These values are fixed at deployment:

- wstETH collateral address;
- oracle address and its feed addresses;
- feed staleness limit;
- maximum debt ratio;
- mint fee;
- redemption fee.

This removes governance-key risk but rules out emergency intervention. Users trust the immutable code, wstETH/Lido mechanics, the configured oracle feeds, and Ethereum execution.

## Launch requirements

Before a real deployment accepts NaN minting:

1. Independently audit the contracts and economic model.
2. Validate oracle addresses, feed behavior, heartbeat, and depeg scenarios on the target chain.
3. Select parameters using stress tests rather than the repository defaults.
4. Seed a publicly disclosed INF buffer large enough for the intended NaN issuance.
5. Publish verified source, deployment transactions, contract addresses, and monitoring.
6. Ensure integrators handle INF series retirement and do not list retired INF as an active reserve claim.
