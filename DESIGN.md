# NaN protocol design

NaN divides one pooled wstETH reserve into a senior stable claim and a junior residual claim. It is inspired by the senior/junior reserve idea explored by USM/FUM, but this repository is a clean-room implementation with a non-upgradeable state machine and authorizer-set risk parameters.

## Accounting

All USD values use 18 decimals. The collateral token must also use 18 decimals.

```text
R = oracle USD value of reserve wstETH
D = NaN total supply
E = max(R - D, 0)
S = permanent INF total supply (including queued, unburned shares)

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

Funding deposits wstETH and mints the permanent INF token. With no supply, it bootstraps at $1; otherwise it uses the greater of current residual NAV and the recovery issuance floor described below. Zero-equity and partial recovery funding are allowed. With outstanding debt, funding is capped so the post-funding ratio remains at or above the minimum; debt-free funding is uncapped. Ordinary NAV quotes use the exact equity/supply ratio, not a rounded per-token price. INF output rounds down.

### Mint

```text
usdIn = collateralIn * oraclePrice
fee = usdIn * mintFee
NaN out = usdIn - fee
```

All collateral, including the fee value, stays in the reserve. Minting requires a nonzero active INF supply and the transaction must leave `D / R` at or below the current maximum.

### Defund

There is no instantaneous INF exit. An INF holder locks a fixed number of tokens with `requestDefund`. Requests are grouped by cohort, with one request per address per cohort. The authorizer can set the withdrawal delay between one and 30 days; it starts at three days. Batching epochs start at one day and can be set between one hour and seven days. A cohort snapshots the delay when its first request arrives and matures that long after its closing boundary. It can be settled permissionlessly during the following day. The actual wait is the snapshotted delay plus the remaining batching time. Changing the delay or epoch length cannot rewrite an open cohort's maturity or expiry. If no one settles it in the window, it expires and the INF can be reclaimed without an oracle. The legacy `series` argument is a namespace fixed at 1; there are no token replacements. Queued INF participates in recapitalization dilution like other outstanding INF.

An epoch-length update takes effect only after the current epoch closes. The schedule anchors the next epoch ID and its start timestamp; IDs remain monotonic rather than being recalculated as timestamp divided by a mutable duration. Repeated updates before that boundary replace the pending duration but preserve the current epoch's ID and end time. Clients must read `currentWithdrawalEpoch()` or record the ID returned by `requestDefund`.

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

### Recovery issuance and recapitalization

INF has one immutable address and recapitalization never cancels old balances. `fund` can accept incremental capital during stress or insolvency. `recapitalize` is an insolvency-only convenience wrapper using exactly the same quote, requiring existing INF supply. Neither requires a single deposit to restore the target ratio. All funding still obeys the minimum debt-ratio cap.

A primary observation of `D/R > max` begins a pricing episode before equity reaches zero. Its initial USD/INF floor is the NAV at the maximum-ratio boundary, rounded up:

```text
boundaryEquity = ceil(D * (BPS - max) / max)
P0 = max(1, ceil(boundaryEquity * WAD / S))
```

`P0`, start time, halving interval `T`, and maximum-ratio exit threshold are snapshotted. The floor is a fixed per-share USD price for the episode, independent of later deposits. By default `T = 1 day`; the authorizer may configure one hour through 30 days for future episodes. This interval is unrelated to the three-day withdrawal delay.

```text
n = floor(elapsed / T)
u = elapsed % T
Pfloor = max(1, ceil((P0 >> n) * (2*T - u) / (2*T)))
```

For `n >= 256`, the floor is one price wei. The schedule linearly interpolates between halvings; it is not a custom exponential approximation. Full-precision arithmetic uses OpenZeppelin Math. While the floor exceeds real NAV, `infOut = floor(usdIn * WAD / Pfloor)`; otherwise `infOut = floor(usdIn * S / E)`. New capital first fills any senior deficit, so its immediate junior NAV can be less than its purchase price, including zero. The issuance floor never changes actual senior liabilities, reserve valuation, INF NAV, or withdrawal entitlements.

An episode clears on a fresh observation only if the debt ratio is at/below its snapshotted maximum AND real NAV has caught up to the remaining floor, or INF supply is zero. A healthy rebound between the target and maximum therefore resets the decay clock; it need not reach the withdrawal target. Restoration of a safe ratio can still precede the end of recovery pricing when real NAV remains below the floor. Removing a binding floor immediately at the ratio boundary would reward splitting one deposit into two; retaining it avoids that price discontinuity. Repeated distress while an episode remains active does not restart its clock. A new breach after an observed completed recovery starts a new episode.

Ignoring rounding, a deposit `C` at a binding price `P` changes NAV to `(R + C - D) / (S + C/P)` once solvent. If pre-deposit NAV is below `P`, post-deposit NAV remains below `P`; otherwise exact-NAV funding preserves NAV. Consequently, at a fixed timestamp/oracle price, splitting a deposit cannot access a lower second-tranche price through the funding operation itself. Solidity fuzz tests also check integer rounding and crossing the target boundary. This does not remove the economic incentive to wait for time decay.

Anyone may call `checkpointRecovery`. Funding and minting observe before and after their changes; primary redemptions do likewise; debt-bearing INF settlement observes before quoting. Oracle-free debt-free settlement does not observe. Failed transactions do not persist observations. View quotes project the current primary observation without storing it. Fallback redemptions do not start or clear recovery. Wall time, including outages, counts once an episode starts; unobserved rebounds cannot reset it. This is not proof of continuous insolvency and needs monitoring.

If a final insolvent redemption exhausts both debt and collateral, surviving INF still exists. An already-active floor continues; absent a recorded episode (for example after fallback-only redemptions), fresh primary observation starts a $1 floor that then decays. Subsequent funding dilutes the old supply without replacing it.

See [RECAPITALIZATION.md](RECAPITALIZATION.md) for design rationale and review gates. This is inspired by FUM's same-token funding principle, not a port of its complete pricing algorithm. Capital arrival is not guaranteed; waiting for cheaper issuance, early-funder losses, extreme dilution, and future INF-governance capture need economic review.

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
- the delay for newly opened INF withdrawal cohorts, between one and 30 days;
- the batching epoch length, between one hour and seven days, effective at the next boundary.
- the recovery issuance-price halving period, between one hour and 30 days, for future episodes only.

The collateral and INF addresses, senior/junior accounting rules, and one-day settlement window remain fixed. Existing withdrawal cohorts retain their snapshotted maturities, and pricing episodes retain their initial price, clock, halving period and exit ratio. The authorizer cannot mint claims, pause users, or extract collateral. Ownership cannot be renounced and changes hands through two-step acceptance. A timelocked DAO should own the reserve in production; this contract does not embed a Governor or TimelockController. Because the authorizer can choose a router with arbitrary prices or change withdrawal/mint capacity, users must monitor governance actions and treat the authorizer as a high-trust dependency. The new accounting cannot be installed into a previously deployed immutable reserve.

Oracle freshness remains a liveness dependency for normal operations. NaN redemption can continue through the Uniswap TWAP fallback when the primary fails. If the primary and either Uniswap pool fail, redemption halts until the authorizer selects a working router; there is no unsafe unpriced redemption path.

## Launch requirements

Before a real deployment accepts NaN minting:

1. Independently audit the contracts and economic model.
2. Validate oracle addresses, feed behavior, heartbeat, and depeg scenarios on the target chain.
3. Select parameters using stress tests rather than the repository defaults.
4. Seed a publicly disclosed INF buffer large enough for the intended NaN issuance.
5. Publish verified source, deployment transactions, contract addresses, and monitoring.
6. Ensure integrators distinguish issuance price from actual NAV, understand dilution, checkpoint recovery observations, and use the revised recapitalization event ABI.
7. Deploy and verify a timelocked authorizer, and rehearse oracle-router rotation and parameter changes.
