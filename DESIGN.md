# NaN protocol design

NaN divides one pooled wstETH reserve into a senior stable claim and a junior residual claim. It is inspired by the senior/junior reserve idea explored by USM/FUM, but this repository is a clean-room implementation with a non-upgradeable state machine and authorizer-set risk parameters.

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

The debt ratio is `D/R`, with governance-set bounds `0 < min < target < max < 100%`. Funding lowers this ratio, while INF withdrawals raise it. The bands are action limits, not automatic rebalancing: external price moves can put the live ratio outside any band without changing balances.

## States

| State | Definition | Consequence |
| --- | --- | --- |
| No debt | `D == 0` | INF owns the reserve |
| Healthy | `R > D` and `D / R <= maxDebtRatio` | Minting may be available; INF exits still require the target ratio and delay |
| Stressed | `R > D` and `D / R > maxDebtRatio` | Funding and redemption available; minting and INF withdrawal settlement remain constrained |
| Insolvent | `R <= D` | NaN redeems pro rata; INF NAV is zero; recapitalization available |

## State transitions

### Fund

Funding deposits wstETH and mints INF at the current residual NAV. The initial INF series bootstraps at $1. With outstanding debt, funding is capped so the post-funding ratio remains at or above the minimum; debt-free bootstrap funding is uncapped. Funding at zero equity is disabled because any ordinary NAV formula would transfer value from the recapitalizer to underwater junior holders.

### Mint

```text
usdIn = collateralIn * oraclePrice
fee = usdIn * mintFee
NaN out = usdIn - fee
```

All collateral, including the fee value, stays in the reserve. Minting requires a nonzero active INF supply and the transaction must leave `D / R` at or below the current maximum.

### Defund

There is no instantaneous INF exit. An INF holder locks a fixed number of active-series tokens with `requestDefund`. Requests are grouped by calendar-day cohort, with one request per address per cohort. The authorizer can set the withdrawal delay between one and 30 days; it starts at three days. A cohort snapshots the delay when its first request arrives and matures that long after its last possible request. It can be settled permissionlessly during the following day. The actual wait is the snapshotted delay plus up to one day. Changing the delay cannot rewrite an open cohort's maturity or expiry. If no one settles it in the window, it expires and the INF can be reclaimed without an oracle.

Settlement uses the current primary price, current reserve/debt state, and current target ratio, never the request-time settings. The aggregate cohort receives up to its proportional residual NAV, limited by the post-settlement target debt ratio. If safe exit capacity is insufficient, the cohort is filled pro rata and unfilled INF is returned on claim. Requests in the same cohort receive the same settlement rate, apart from one-wei rounding. A requester cannot force a payout merely because three days have elapsed.

Pending INF remains in active total supply, so it continues to participate in gains and losses until settlement. The filled portion is burned at settlement. The corresponding wstETH becomes claimable and is excluded from `reserveCollateral()` immediately, even before a user claims it; this prevents NaN redemptions or later INF exits from consuming earmarked collateral. Claims are pull-based and oracle-free. A fully debt-free reserve can settle INF withdrawals in kind without an oracle and return every collateral unit to the final INF claimant.

The queue uses the asynchronous request/claim pattern but is not ERC-7540 compliant: NaNReserve is not an ERC-4626 vault, because the same collateral backs senior NaN liabilities and junior INF equity. The withdrawal delay is not an economic guarantee. A price rise that persists through settlement can still enable a large INF exit, and an adverse move after settlement can still stress NaN.

### Redeem

When `R > D`, NaN redeems at $1 less the redemption fee. The retained fee increases INF NAV and redemption improves the collateral ratio.

When `R <= D`, the explicit fee is disabled and the gross redemption price is:

```text
NaN redemption price = R / D
```

This preserves the reserve/debt ratio across redemptions, apart from conservative rounding. The final insolvent redeemer receives all remaining collateral so rounding dust cannot become trapped.

### Recapitalize

At zero junior equity, a recapitalizer must restore the reserve to the configured target debt ratio:

```text
required reserve = ceil(D / targetDebtRatio)
required capital = required reserve - R
new INF out = R + usdIn - D
```

For outstanding debt, recapitalization therefore exits directly into the Healthy state rather than merely crossing back above 100% collateralization. The old INF contract is retired atomically and a new OpenZeppelin-based INF contract becomes active. The new series starts with NAV of $1; the recapitalizer explicitly bears the old senior shortfall and supplies a fresh junior buffer. This is a wipeout model, not an auction. Applications must follow `inf()`, `juniorSeries`, and `Recapitalized` rather than assuming INF has a permanent address.

An overfunded recapitalization cannot push the post-recapitalization debt ratio below the configured minimum. The target and minimum therefore define an allowed recapitalization range while debt remains outstanding.

If the last insolvent NaN redemption exhausts both debt and collateral, `recapitalize` can similarly retire the worthless INF series and restart the system without a senior shortfall.

## Oracle

The selected router uses a direct Chainlink stETH/USD feed in normal operation:

```text
wstETH/USD = stETH/USD * stEthPerToken()
```

The primary feed must have a positive answer, a valid timestamp within that router's staleness limit, and a complete round. A direct stETH/USD market quote captures a stETH depeg without a separate stETH/ETH call.

On primary failure, only NaN redemption can call the configured Uniswap v3 fallback. It computes a wstETH/WETH TWAP and a WETH/USDC TWAP over the same window, then quotes one wstETH through both pools. Pool identities are checked against the configured factory. Each pool must have the full observation history, adequate harmonic mean liquidity over the window, and adequate current liquidity. The fallback assumes USDC is worth $1. Uniswap's tick math and OpenZeppelin's full-precision multiplication and division calculate the quote.

Each router applies its configured upward premium to the fallback quote. This pays less collateral per redeemed NaN and protects the reserve from modestly low fallback valuations; it cannot make manipulated TWAPs or a USDC premium safe. The two pools can lose liquidity or migrate over the protocol's lifetime; the authorizer may deploy and select a replacement router.

Minting, funding, debt-bearing INF settlement, and recapitalization require the primary. INF withdrawal requests, claims, expirations, and debt-free settlement do not. The reserve's ordinary health and NAV views also require the primary, while `nanRedemptionPriceUsd()` and `redemptionCollateralPriceUsd()` follow the actual redemption path. If both sources are unavailable, redemption fails closed.

## Governance and trust model

The reserve has no upgrade path. Its OpenZeppelin two-step owner is the authorizer and may update:

- the complete oracle router, including the effective primary feed, TWAP pools, staleness limit, liquidity thresholds, and fallback premium, by selecting a newly deployed router;
- the minimum, target, and maximum debt ratios, with strict ordering and maximum below 100%;
- mint and redemption fees, each capped at 10%.
- the delay for newly opened INF withdrawal cohorts, between one and 30 days.

The collateral address, senior/junior accounting rules, cohort length, and settlement window remain fixed. Existing withdrawal cohorts retain their snapshotted maturities. The authorizer cannot mint claims, pause users, or extract collateral. Ownership cannot be renounced and changes hands through two-step acceptance. A timelocked DAO should own the reserve in production; this contract does not embed a Governor or TimelockController. Because the authorizer can choose a router with arbitrary prices or change withdrawal/mint capacity, users must monitor governance actions and treat the authorizer as a high-trust dependency.

Oracle freshness remains a liveness dependency for normal operations. NaN redemption can continue through the Uniswap TWAP fallback when the primary fails. If the primary and either Uniswap pool fail, redemption halts until the authorizer selects a working router; there is no unsafe unpriced redemption path.

## Launch requirements

Before a real deployment accepts NaN minting:

1. Independently audit the contracts and economic model.
2. Validate oracle addresses, feed behavior, heartbeat, and depeg scenarios on the target chain.
3. Select parameters using stress tests rather than the repository defaults.
4. Seed a publicly disclosed INF buffer large enough for the intended NaN issuance.
5. Publish verified source, deployment transactions, contract addresses, and monitoring.
6. Ensure integrators handle INF series retirement and do not list retired INF as an active reserve claim.
7. Deploy and verify a timelocked authorizer, and rehearse oracle-router rotation and parameter changes.
