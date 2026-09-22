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

All collateral, including the fee value, stays in the reserve. Minting requires a nonzero active INF supply and the transaction must leave `D / R` at or below the immutable maximum.

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

At zero junior equity, a recapitalizer must restore the reserve to the configured normal debt limit:

```text
required reserve = ceil(D / maxDebtRatio)
required capital = required reserve - R
new INF out = R + usdIn - D
```

For outstanding debt, recapitalization therefore exits directly into the Healthy state rather than merely crossing back above 100% collateralization. The old INF contract is retired atomically and a new OpenZeppelin-based INF contract becomes active. The new series starts with NAV of $1; the recapitalizer explicitly bears the old senior shortfall and supplies a fresh junior buffer. This is a wipeout model, not an auction. Applications must follow `inf()`, `juniorSeries`, and `Recapitalized` rather than assuming INF has a permanent address.

If the last insolvent NaN redemption exhausts both debt and collateral, `recapitalize` can similarly retire the worthless INF series and restart the system without a senior shortfall.

## Oracle

The immutable router uses a direct Chainlink stETH/USD feed in normal operation:

```text
wstETH/USD = stETH/USD * stEthPerToken()
```

The primary feed must have a positive answer, a valid timestamp within the immutable staleness limit, and a complete round. A direct stETH/USD market quote captures a stETH depeg without a separate stETH/ETH call.

On primary failure, only NaN redemption can call the immutable Uniswap v3 fallback. It computes a wstETH/WETH TWAP and a WETH/USDC TWAP over the same window, then quotes one wstETH through both pools. Pool identities are checked against the configured factory. Each pool must have the full observation history, adequate harmonic mean liquidity over the window, and adequate current liquidity. The fallback assumes USDC is worth $1. Uniswap's tick math and OpenZeppelin's full-precision multiplication and division calculate the quote.

The router applies an immutable upward premium to the fallback quote. This pays less collateral per redeemed NaN and protects the reserve from modestly low fallback valuations; it cannot make manipulated TWAPs or a USDC premium safe. The two pools can lose liquidity or migrate over the protocol's lifetime, so the fallback reduces rather than eliminates permanent liveness risk.

Minting, funding, defunding, and recapitalization require the primary. The reserve's ordinary health and NAV views also require the primary, while `nanRedemptionPriceUsd()` and `redemptionCollateralPriceUsd()` follow the actual redemption path. If both sources are unavailable, redemption fails closed.

## Immutability and trust model

The reserve has no owner and no upgrade path. These values are fixed at deployment:

- wstETH collateral address;
- oracle address, primary feed, Uniswap pool and token addresses, TWAP window, minimum pool liquidity, and fallback premium;
- feed staleness limit;
- maximum debt ratio;
- mint fee;
- redemption fee.

This removes governance-key risk but rules out emergency intervention. Users trust the immutable code, wstETH/Lido mechanics, the configured oracle feeds, and Ethereum execution.

Oracle freshness remains a liveness dependency for normal operations. NaN redemption can continue through the Uniswap TWAP fallback when the primary fails. If the primary and either Uniswap pool fail, redemption halts. A terminal oracle-failure settlement path remains an unresolved design question rather than being hidden behind an admin key.

## Launch requirements

Before a real deployment accepts NaN minting:

1. Independently audit the contracts and economic model.
2. Validate oracle addresses, feed behavior, heartbeat, and depeg scenarios on the target chain.
3. Select parameters using stress tests rather than the repository defaults.
4. Seed a publicly disclosed INF buffer large enough for the intended NaN issuance.
5. Publish verified source, deployment transactions, contract addresses, and monitoring.
6. Ensure integrators handle INF series retirement and do not list retired INF as an active reserve claim.
