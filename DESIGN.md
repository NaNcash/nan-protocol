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

Funding must mint at least one billion INF base units, and any nonzero supply remaining after a withdrawal must be at least that large. Partial burns are capped to preserve this floor; a complete debt-free exit may reduce supply to zero. Both `previewFund` and `fund` reject coarser issuance, so donations cannot make a successful depositor lose more than one billionth of its exact share quote to share rounding. Aggregate withdrawals that pay zero collateral burn no INF. These checks protect bootstrap and near-drain states without virtual senior debt or locked residual claims.

There is no instantaneous INF exit. An INF holder locks a fixed number of tokens with `requestDefund`. Requests are grouped by cohort, with one request per address per cohort. The authorizer can set the withdrawal delay between one and 30 days; it starts at three days. Batching epochs start at one day and can be set between one hour and seven days. A cohort snapshots the delay when its first request arrives and matures that long after its closing boundary. It can be settled permissionlessly during the following day. The actual wait is the snapshotted delay plus the remaining batching time. Changing the delay or epoch length cannot rewrite an open cohort's maturity or expiry. At expiry anyone can finalize it without an oracle, opening claims for accumulated collateral and any unfilled INF. The legacy `series` argument is a namespace fixed at 1; there are no token replacements. Queued INF participates in recapitalization dilution like other outstanding INF.

An epoch-length update takes effect only after the current epoch closes. The schedule anchors the next epoch ID and its start timestamp; IDs remain monotonic rather than being recalculated as timestamp divided by a mutable duration. Repeated updates before that boundary replace the pending duration but preserve the current epoch's ID and end time. Clients must read `currentWithdrawalEpoch()` or record the ID returned by `requestDefund`.

Settlement uses the current primary price, current reserve/debt state, and current target ratio, never the request-time settings. The aggregate cohort receives up to its proportional residual NAV, limited by the post-settlement target debt ratio. If safe exit capacity is insufficient, a partial fill accumulates collateral and burned INF without closing the cohort. Anyone may retry the remaining INF during the original window, at the then-current price and target ratio. Zero-capacity settlement reverts without changing state. Claims open only after all requested INF is filled or after permissionless expiry finalization. This prevents a temporary mint or tiny fill from forcing the entire remainder to restart its withdrawal delay. The original expiry still applies; there is no guarantee of capacity throughout the window. Unfilled INF is returned on claim. Each request's filled INF is the difference between its rounded cumulative fill boundaries. Collateral is allocated over that same filled-INF interval, so a request with zero filled INF receives zero collateral. Each filled INF unit receives the same collateral rate, apart from one-wei collateral rounding. Prefix differences distribute all filled INF and earmarked collateral regardless of claim order. An expired cohort with no fills refunds every requested INF unit without allocating collateral. Expiry after partial fills preserves all earmarked collateral and burns, and refunds only the unfilled INF. Across multiple fills at different prices, claim allocation uses cumulative filled INF and cumulative collateral, so each requester receives the same blended rate. A requester cannot force a payout merely because three days have elapsed.

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

INF has one immutable address and recapitalization never cancels old balances. `fund` is the sole INF deposit entry point and accepts incremental capital during stress or insolvency. A single deposit need not restore the target ratio. All funding still obeys the minimum debt-ratio cap.

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

If governance lowers the current maximum, an observation can satisfy the old episode's exit threshold while still breaching the new maximum. That same observation ends the old episode and starts a replacement using the current maximum and halving interval. View quotes project the replacement floor, and funding stores the replacement before issuing INF. Checkpointing immediately before funding at the same state, price, and time therefore cannot change the issuance quote. A stored replacement emits `RecoveryEnded` followed by `RecoveryStarted`.

Ignoring rounding, a deposit `C` at a binding price `P` changes NAV to `(R + C - D) / (S + C/P)` once solvent. If pre-deposit NAV is below `P`, post-deposit NAV remains below `P`; otherwise exact-NAV funding preserves NAV. Consequently, at a fixed timestamp/oracle price, splitting a deposit cannot access a lower second-tranche price through the funding operation itself. Solidity fuzz tests also check integer rounding and crossing the target boundary. This does not remove the economic incentive to wait for time decay.

Anyone may call `checkpointRecovery`. Funding and minting observe before and after their changes; redemptions do likewise; debt-bearing INF settlement observes before quoting. Oracle-free debt-free settlement does not observe. Failed transactions do not persist observations. View quotes project the current primary observation without storing it. Primary outages halt redemption and cannot start or clear recovery. Wall time, including outages, counts once an episode starts; unobserved rebounds cannot reset it. This is not proof of continuous insolvency and needs monitoring.

If a final insolvent redemption exhausts both debt and collateral, surviving INF still exists. An already-active floor continues; absent a recorded episode, a fresh primary observation starts a $1 floor that then decays. Subsequent funding dilutes the old supply without replacing it.

See [RECAPITALIZATION.md](RECAPITALIZATION.md) for design rationale and review gates. This is inspired by FUM's same-token funding principle, not a port of its complete pricing algorithm. Capital arrival is not guaranteed; waiting for cheaper issuance, early-funder losses, extreme dilution, and future INF-governance capture need economic review.

## Oracle

The selected router uses a direct Chainlink stETH/USD feed in normal operation:

```text
wstETH/USD = stETH/USD * stEthPerToken()
```

The primary feed must have a positive answer, a valid timestamp within that router's staleness limit, and a complete round. A direct stETH/USD market quote captures a stETH depeg without a separate stETH/ETH call.

NaN redemption requires the fresh primary, including in insolvency. If the primary fails, redemption halts even if the fallback is valid. A lagging TWAP plus a fixed premium cannot establish a conservative bound against current market value during an upward move; paying against it can transfer junior equity to redeemers. The protocol explicitly trades outage availability for removing that payout path.

The existing router and deployment ABI retain a legacy diagnostic fallback. It computes wstETH/WETH and WETH/USDC TWAPs over the same window, checks canonical pool identities, observation history and current/harmonic liquidity, assumes USDC equals $1, and adds its configured premium. `WstEthUsdOracle.redemptionPrice()` may return this diagnostic quote; NaNReserve uses only `oracle.price()` for redemption. The reserve's `redemptionCollateralPriceUsd()` keeps its tuple ABI but always reports `fallbackUsed = false` and reverts when the primary is unavailable.

Minting, funding (including during insolvency), redemption, and debt-bearing INF settlement require the primary. INF withdrawal requests, claims, expirations, and debt-free settlement do not. Oracle-free expiry preserves partial settlements during outages. Health, NAV, and redemption-price views require the primary.

## Governance and trust model

The reserve has no upgrade path. Its OpenZeppelin two-step owner is the authorizer and may update:

- the complete oracle router, including the effective primary feed, TWAP pools, staleness limit, liquidity thresholds, and fallback premium, by selecting a newly deployed router;
- the minimum, target, and maximum debt ratios, with strict ordering and maximum below 100%;
- mint and redemption fees, each capped at 10%.
- the delay for newly opened INF withdrawal cohorts, between one and 30 days;
- the batching epoch length, between one hour and seven days, effective at the next boundary.
- the recovery issuance-price halving period, between one hour and 30 days, for future episodes only.

The collateral and INF addresses, senior/junior accounting rules, and one-day settlement window remain fixed. Existing withdrawal cohorts retain their snapshotted maturities, and pricing episodes retain their initial price, clock, halving period and exit ratio. The authorizer cannot mint claims, pause users, or extract collateral. Ownership cannot be renounced and changes hands through two-step acceptance. A timelocked DAO should own the reserve in production; this contract does not embed a Governor or TimelockController. Because the authorizer can choose a router with arbitrary prices or change withdrawal/mint capacity, users must monitor governance actions and treat the authorizer as a high-trust dependency. The new accounting cannot be installed into a previously deployed immutable reserve.

Oracle freshness remains a liveness dependency for all priced operations. NaN redemption halts until the primary recovers or the authorizer selects a working router. There is no fallback-priced or unpriced redemption path.

## Launch requirements

Before a real deployment accepts NaN minting:

1. Independently audit the contracts and economic model.
2. Validate oracle addresses, feed behavior, heartbeat, and depeg scenarios on the target chain.
3. Select parameters using stress tests rather than the repository defaults.
4. Seed a publicly disclosed INF buffer large enough for the intended NaN issuance.
5. Publish verified source, deployment transactions, contract addresses, and monitoring.
6. Ensure integrators distinguish issuance price from actual NAV, understand dilution, checkpoint recovery observations, and use `fund` for all INF deposits.
7. Deploy and verify a timelocked authorizer, and rehearse oracle-router rotation and parameter changes.
