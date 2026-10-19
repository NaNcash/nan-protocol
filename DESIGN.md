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

The debt ratio is `D/R`, with governance-set bounds `0 < target < max < 100%`. Funding lowers this ratio, while INF withdrawals raise it. The target limits junior withdrawals and the maximum limits senior issuance. These are action limits, not automatic rebalancing: external price moves can put the live ratio outside any band without changing balances.

## States

| State | Definition | Consequence |
| --- | --- | --- |
| No debt | `D == 0` | INF owns the reserve |
| Healthy | `R > D` and `D / R <= maxDebtRatio` | Minting may be available; INF exits still require the target ratio and delay |
| Stressed | `R > D` and `D / R > maxDebtRatio` | Funding and redemption available; minting and INF withdrawal settlement remain constrained |
| Insolvent | `R <= D` | NaN redeems pro rata; INF NAV is zero; recapitalization available |

## State transitions

### Fund

Funding deposits wstETH and mints the permanent INF token. With no supply, it bootstraps at $1; otherwise it uses the greater of current residual NAV and the recovery issuance floor described below. Zero-equity and partial recovery funding are allowed. Funding is not capped by the debt ratio, whether debt exists or not. It can cross below any prior ratio or continue from a low-ratio state. At exact NAV it preserves existing per-token NAV apart from rounding, while reducing leverage and sharing future fees across more equity. Ordinary NAV quotes use the exact equity/supply ratio, not a rounded per-token price. INF output rounds down.

### Mint

```text
usdIn = collateralIn * oraclePrice
fee = usdIn * mintFee
NaN out = usdIn - fee
```

All collateral, including the fee value, stays in the reserve. Minting requires at least `MIN_INF_SUPPLY` active INF base units and the transaction must leave `D / R` at or below the current maximum.

### Defund

`MIN_INF_SUPPLY` (one billion INF base units) is the minimum supply for new NaN issuance and the minimum output of every funding deposit. It is not a withdrawal floor. Settlements may leave any smaller positive supply, including one base unit, so unrelated holders can withdraw independently through separate cohorts. A complete debt-free exit may reduce supply to zero. Existing NaN redemptions continue below the operating minimum; new NaN minting reverts with `NoJuniorCapital` until funding restores it. Every successful `fund` mints at least `MIN_INF_SUPPLY`, atomically restoring sufficient operating supply, even when just one INF base unit was left. The permanent INF address and existing balances are preserved; no locked shares, virtual claims, finalization vote, or cross-cohort aggregation are introduced.

Both `previewFund` and `fund` reject coarse issuance regardless of existing supply or the caller's minimum output. If the exact share quote is `q` and its integer output `n = floor(q)` is at least one billion, `(q - n) / q < 1 / 1e9`. Thus share-quote rounding stays below one billionth even after a withdrawal leaves one share. For example, leaving one INF base unit and donating one wstETH still makes a 1.999-wstETH victim deposit revert with `InsufficientInfPrecision`: a quote of only one share is rejected before collateral is taken. At normal NAV, quotes retain the exact equity/supply ratio; the recovery issuance floor and minimum output also apply below the operating minimum. Small deposits may remain unavailable after a large donation or while the recovery floor binds; accepting coarse issuance to reopen funding would compromise this protection.

All debt-bearing settlements still require a fresh primary and preserve the target debt ratio, which prevents burning the last INF while senior debt remains. A partial fill can cross below the operating minimum, then remain open for further capacity within the same window. Aggregate withdrawals that pay zero collateral still burn no INF. A fragment worth less than one collateral base unit can still require more backing or aggregation to become payable; removing the supply cap does not create fractional collateral units. At zero debt the final remaining INF receives all unearmarked collateral in kind, including conversion dust, and subsequent funding can bootstrap normally.

There is no instantaneous INF exit. An INF holder locks a fixed number of tokens with `requestDefund`. Requests are grouped by cohort, with one request per address per cohort. The authorizer can set the withdrawal delay between one and 30 days; it starts at three days. Batching epochs start at one day and can be set between one hour and seven days. A cohort snapshots the delay when its first request arrives and matures that long after its closing boundary. It can be settled permissionlessly during the following day. The actual wait is the snapshotted delay plus the remaining batching time. Changing the delay or epoch length cannot rewrite an open cohort's maturity or expiry. At expiry anyone can finalize it without an oracle, opening claims for accumulated collateral and any unfilled INF. The legacy `series` argument is a namespace fixed at 1; there are no token replacements. Queued INF participates in recapitalization dilution like other outstanding INF.

An epoch-length update takes effect only after the current epoch closes. The schedule anchors the next epoch ID and its start timestamp; IDs remain monotonic rather than being recalculated as timestamp divided by a mutable duration. Repeated updates before that boundary replace the pending duration but preserve the current epoch's ID and end time. Clients must read `currentWithdrawalEpoch()` or record the ID returned by `requestDefund`.

Inter-cohort priority is **first successful settlement**, not request order or maturity order. Each successful call consumes the shared capacity then available, including retries of a partially filled cohort. Within a cohort, allocation remains proportional to its requests. When epochs are shorter than the one-day settlement window, adjacent windows can overlap and a later cohort can consume capacity before an earlier eligible cohort. Reducing the delay for new cohorts can also make a later cohort mature before an older one, even though the older cohort's maturity and expiry do not change. Default one-day epochs with unchanged equal delays have disjoint windows. Governance and integrators must account for these ordering consequences before changing delays or epoch lengths. No FIFO entitlement or future capacity is reserved by a request. Permissionless settlement and expiry do not wait for empty, expired, zero-capacity, or unattended earlier cohorts; capacity exhaustion can leave another cohort wholly unfilled until expiry and refund.

Settlement uses the current primary price, current reserve/debt state, and current target ratio, never the request-time settings. The aggregate cohort receives up to its proportional residual NAV, limited by the post-settlement target debt ratio. If safe exit capacity is insufficient, a partial fill accumulates collateral and burned INF without closing the cohort. Anyone may retry the remaining INF during the original window, at the then-current price and target ratio. Zero-capacity settlement reverts without changing state. Claims open after all requested INF is filled, after a positive payout leaves only collateral-rounding dust, or after permissionless expiry finalization. Dust is evaluated against post-fill supply and backing, at the same primary price used for the fill when debt exists: the entire remaining INF must quote zero collateral at residual NAV, ignoring the target-ratio capacity limit. Such a cohort finalizes immediately and refunds its unfilled INF on claim. Exhausting target-ratio capacity alone never closes a cohort; even a remainder worth one collateral base unit remains retryable, including below `MIN_INF_SUPPLY`. A zero-payout attempt still reverts without finalizing. This prevents a temporary mint or tiny fill from forcing a valuable remainder to restart its withdrawal delay. The original expiry still applies; there is no guarantee of capacity throughout the window. Unfilled INF is returned on claim. Each request's filled INF is the difference between its rounded cumulative fill boundaries. Collateral is allocated over that same filled-INF interval, so a request with zero filled INF receives zero collateral. Each filled INF unit receives the same collateral rate, apart from one-wei collateral rounding. Prefix differences distribute all filled INF and earmarked collateral regardless of claim order. An expired cohort with no fills refunds every requested INF unit without allocating collateral. Expiry after partial fills preserves all earmarked collateral and burns, and refunds only the unfilled INF. Across multiple fills at different prices, claim allocation uses cumulative filled INF and cumulative collateral, so each requester receives the same blended rate. A requester cannot force a payout merely because three days have elapsed.

Pending INF remains in active total supply, so it continues to participate in gains and losses until settlement. The filled portion is burned at settlement. The corresponding wstETH becomes claimable and is excluded from `reserveCollateral()` immediately, even before a user claims it; this prevents NaN redemptions or later INF exits from consuming earmarked collateral. Claims are pull-based and oracle-free. A fully debt-free reserve can settle INF withdrawals in kind without an oracle and return every collateral unit to the final INF claimant.

`maxDefundableUsd()` reports the USD value of the same collateral budget used by debt-bearing settlement. Required backing is `ceil(ceil(D * BPS / targetDebtRatioBps) * 1e18 / price)` collateral base units. Capacity is `floor(max(reserveCollateral - requiredBacking, 0) * price / 1e18)`. With no debt, the budget is all unearmarked collateral. This is a capacity bound at the current primary price, not a guaranteed payout or a quote for a particular request: converting that budget into whole INF, then USD, then collateral still rounds output down. A positive capacity can therefore produce a smaller payout or zero for a tiny request. Other settlements, prices and parameter changes can change capacity before execution; clients must read current state and inspect actual fills. The helper continues to require the primary price even though debt-free settlement itself is oracle-free.

The queue uses the asynchronous request/claim pattern but is not ERC-7540 compliant: NaNReserve is not an ERC-4626 vault, because the same collateral backs senior NaN liabilities and junior INF equity. The withdrawal delay is not an economic guarantee. A price rise that persists through settlement can still enable a large INF exit, and an adverse move after settlement can still stress NaN.

### Redeem

When `R > D`, NaN redeems at $1 less an equity-bounded redemption fee. For a burn of `X` NaN, define `E = R - D` using pre-redemption backing (excluding earmarked withdrawal collateral). In 18-decimal USD units:

```text
configuredFee = floor(X * redeemFeeBps / 10_000)
equityCap     = floor(X * E / D)
feeUsd        = min(configuredFee, equityCap)
netUsdOut     = X - feeUsd
collateralOut = floor(netUsdOut * 1e18 / collateralPriceUsd)
```

Thus the effective fee rate ramps from zero at equality to the configured rate when `E / D` reaches `redeemFeeBps / 10_000`, apart from integer rounding. A tiny collateral donation can increase a given redemption's equity cap only by its proportional share of the additional USD backing, with base-unit rounding. At $100,000 debt, a $2,000 collateral price, and a 10 bp fee, donating one collateral wei at equality increases equity by 2,000 USD base units. A 10,000 NaN redemption retains 200 USD base units rather than the full $10 fee, changing collateral output by one wei.

The retained fee increases INF equity; collateral conversion dust also remains in backing. Neither the cap nor the fee spends existing junior equity. The full configured fee remains available in adequately capitalized reserves, and solvent redemption improves the collateral ratio. A full solvent redemption leaves the original equity plus its fee and conversion dust for INF.

**Split redemptions recompute the cap from current equity and remaining debt.** The cap is proportional to the burned share of debt; using the entire equity balance as each transaction's cap would let repeated small burns each charge the whole surplus. Retained fees and conversion dust increase equity, while each burn decreases debt, so later burns can pay a higher rate. Splitting is not fee-invariant and can cost more than a single burn; it cannot increase aggregate solvent output except for base-unit fee rounding. For example, at $100,000 debt and $10 equity with a 10 bp configured fee, a full burn pays $10. Two $50,000 burns pay $5 then $15, leaving $30 equity instead of $20. Across any sequence, each tranche's fee is still bounded by its configured fee and its then-current proportional equity cap. This policy deliberately retains earned fees in junior equity rather than tracking a historical fee-free equity balance. Integrators should quote the intended transaction and retain minimum-output protection. This path dependence and its incentives remain part of the prototype's required independent economic review.

When `R <= D`, the explicit fee is disabled and the gross redemption price is:

```text
NaN redemption price = R / D
```

This preserves the reserve/debt ratio across redemptions, apart from conservative rounding. The final insolvent redeemer receives all remaining collateral so rounding dust cannot become trapped.

### Recovery issuance and recapitalization

INF has one immutable address and recapitalization never cancels old balances. `fund` is the sole INF deposit entry point and accepts incremental capital during stress or insolvency. A single deposit need not restore the target ratio. Funding has no debt-ratio cap; the primary-oracle, issuance-floor, precision, slippage, and collateral-transfer checks still apply.

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

Router construction does not require a live diagnostic quote: reverting and zero-valued fallbacks are accepted. Nonzero addresses, fallback bytecode, primary feed decimals, staleness and premium bounds remain validated; a successful fallback probe must return the single 32-byte `price()` ABI value. A reverting probe cannot distinguish a temporary outage from a wrong interface, so deployment review must verify the fallback implementation and configuration separately. The Uniswap fallback itself still validates its canonical pools, token decimals, observation window and nonzero liquidity thresholds at construction. A healthy primary bypasses fallback diagnostics. If the primary is unavailable and the fallback reverts or returns zero, `redemptionPrice()` reports `FallbackUnavailable`; diagnostics resume when a usable quote returns. Reserve payout authorization never uses this diagnostic path.

TWAP observation arrays must each contain exactly two values. Tick and seconds-per-liquidity deltas use modular subtraction in `int56` and `uint160`, respectively, before widening, matching the [Uniswap V3 accumulator semantics](https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol). Negative mean ticks round toward negative infinity. Zero/impossible liquidity deltas and out-of-range mean ticks fail closed; current and historical liquidity thresholds still apply after wraparound.

Minting, funding (including during insolvency), redemption, and debt-bearing INF settlement require the primary. INF withdrawal requests, claims, expirations, and debt-free settlement do not. Oracle-free expiry preserves partial settlements during outages. Health, NAV, and redemption-price views require the primary.

## Governance and trust model

The reserve has no upgrade path. Its OpenZeppelin two-step owner is the authorizer and may update:

- the complete oracle router, including the effective primary feed, TWAP pools, staleness limit, liquidity thresholds, and fallback premium, by selecting a newly deployed router;
- the target and maximum debt ratios, with `0 < target < max < 10,000` basis points;
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
