# Invariant Map

> NaN Protocol | 57 guards | 25 inferred properties | 3 not enforced on-chain

Production scope only. G-31 was removed with the INF funding cap; remaining guard IDs are retained for reference. Guards below reproduce source predicates with whitespace folded; duplicate token-constructor guards share G-38. Standard inherited ERC-20 semantics are resolved from the pinned OpenZeppelin implementation. **On-chain: No** records an unvalidated assumption or diagnostic policy property, not a confirmed vulnerability. Spec claims are labeled **(per spec)** and checked against the current code.

## 1. Enforced Guards (Reference)

Per-call preconditions, not independently falsifiable global invariants. Generic zero-amount/recipient input checks with no persistent-state implication are omitted.

#### G-1
`if (newPeriod < MIN_RECOVERY_HALVING_PERIOD || newPeriod > MAX_RECOVERY_HALVING_PERIOD)` · `src/NaNReserve.sol:182` · Purpose: bound decay settings used by future recovery episodes.

#### G-2
`if (newDelay < MIN_INF_WITHDRAWAL_DELAY || newDelay > MAX_INF_WITHDRAWAL_DELAY)` · `src/NaNReserve.sol:192` · Purpose: bound waiting periods assigned to newly opened withdrawal cohorts.

#### G-3
`if (newLength < MIN_INF_WITHDRAWAL_EPOCH || newLength > MAX_INF_WITHDRAWAL_EPOCH)` · `src/NaNReserve.sol:203` · Purpose: keep future epoch arithmetic within the permitted duration policy.

#### G-4
`if (address(newOracle) == address(0))` · `src/NaNReserve.sol:220` · Purpose: preserve a nonzero pricing dependency when rotating the router.

#### G-5
`if (address(newOracle).code.length == 0)` · `src/NaNReserve.sol:221` · Purpose: reject a router address that cannot execute contract price methods.

#### G-6
`if (newOracle.price() == 0)` · `src/NaNReserve.sol:222` · Purpose: require a usable primary quote at router selection time.

#### G-7
`if (redemptionPrice == 0)` · `src/NaNReserve.sol:224` · Purpose: require a usable redemption quote at router selection time.

#### G-8
`if (targetBps == 0 || targetBps >= maxBps || maxBps >= BPS)` · `src/NaNReserve.sol:231` · Purpose: preserve strict ordering and sub-100-percent risk parameters.

#### G-9
`if (mintBps > MAX_FEE_BPS || redeemBps > MAX_FEE_BPS)` · `src/NaNReserve.sol:241` · Purpose: cap fees retained from senior issuance and solvent redemption.

#### G-10
`if (IERC20Metadata(address(collateral_)).decimals() != 18)` · `src/NaNReserve.sol:156` · Purpose: match collateral accounting to the fixed WAD unit.

#### G-11
`if (address(collateral_) == address(0) || address(oracle_) == address(0))` · `src/NaNReserve.sol:153` · Purpose: bind construction to nonzero collateral and oracle dependencies.

#### G-12
`if (price == 0)` · `src/NaNReserve.sol:253` · Purpose: prevent zero conversion denominators or worthless primary valuation.

#### G-13
`if (price == 0)` · `src/NaNReserve.sol:260` · Purpose: require nonzero valuation on the actual senior redemption route.

#### G-14
`if (request.infAmount != 0)` · `src/NaNReserve.sol:447` · Purpose: prevent overwriting an existing request interval for the same account and cohort.

#### G-15
`if (requestEpoch.requestedInf == 0)` · `src/NaNReserve.sol:465` · Purpose: prevent settlement of an unopened withdrawal cohort.

#### G-16
`if (requestEpoch.settled)` · `src/NaNReserve.sol:466` · Purpose: prevent repeated fill, burn, or earmarking for one cohort.

#### G-17
`if (block.timestamp < requestEpoch.maturity)` · `src/NaNReserve.sol:467` · Purpose: enforce the cohort maturity snapshotted on opening.

#### G-18
`if (block.timestamp >= uint256(requestEpoch.maturity) + INF_SETTLEMENT_WINDOW)` · `src/NaNReserve.sol:468` · Purpose: confine price-dependent settlement to its fixed one-day window.

#### G-19
`if (requestEpoch.requestedInf == 0)` · `src/NaNReserve.sol:490` · Purpose: prevent expiry from fabricating settlement state for an unopened cohort.

#### G-20
`if (requestEpoch.settled)` · `src/NaNReserve.sol:491` · Purpose: prevent expiry from replacing an already settled cohort outcome.

#### G-21
`if (block.timestamp < uint256(requestEpoch.maturity) + INF_SETTLEMENT_WINDOW)` · `src/NaNReserve.sol:492` · Purpose: retain the settlement opportunity until its entire window has elapsed.

#### G-22
`if (!requestEpoch.settled)` · `src/NaNReserve.sol:506` · Purpose: prevent claims before a cohort outcome has been fixed.

#### G-23
`if (requestedInf == 0)` · `src/NaNReserve.sol:509` · Purpose: confine claims to the caller's positive unclaimed interval.

#### G-24
`if (collateralOut < minCollateralOut)` · `src/NaNReserve.sol:518` · Purpose: enforce the holder's minimum payout against the stored cohort allocation.

#### G-25
`if (inf.totalSupply() == 0)` · `src/NaNReserve.sol:540` · Purpose: require active junior supply before adding senior liabilities.

#### G-26
`if (nanOut == 0 || nanOut < minNanOut)` · `src/NaNReserve.sol:550` · Purpose: prevent zero or below-minimum senior issuance after fees and rounding.

#### G-27
`if (!_withinMaxDebtRatio(debtAfter, reserveAfter))` · `src/NaNReserve.sol:553` · Purpose: bound senior issuance by the configured post-trade maximum debt ratio.

#### G-28
`if (debtBefore == 0)` · `src/NaNReserve.sol:574` · Purpose: prevent redemption math without outstanding senior debt.

#### G-29
`if (collateralOut == 0 || collateralOut < minCollateralOut)` · `src/NaNReserve.sol:589` · Purpose: reject dust or below-minimum senior collateral payouts.

#### G-30
`if (!_withinDebtRatio(debt, _collateralToUsd(reserve - collateralOut, price), targetDebtRatioBps))` · `src/NaNReserve.sol:632` · Purpose: retain enough backing after junior settlement for the target debt ratio.

#### G-32
`if (infOut == 0 || infOut < minInfOut)` · `src/NaNReserve.sol:430` · Purpose: prevent zero or below-minimum junior issuance after NAV/floor pricing.

#### G-33
`if (received != amount)` · `src/NaNReserve.sol:730` · Purpose: require actual incoming collateral to equal the amount used in issuance math.

#### G-34
`if (msg.sender != reserve)` · `src/NaNToken.sol:21` · Purpose: confine senior supply creation to the immutable reserve.

#### G-35
`if (msg.sender != reserve)` · `src/NaNToken.sol:26` · Purpose: confine senior supply destruction to the immutable reserve.

#### G-36
`if (msg.sender != reserve)` · `src/INFToken.sol:21` · Purpose: confine junior supply creation to the immutable reserve.

#### G-37
`if (msg.sender != reserve)` · `src/INFToken.sol:26` · Purpose: confine junior supply destruction to the immutable reserve.

#### G-38
`if (reserve_ == address(0))` · `src/NaNToken.sol:16` · Purpose: avoid deploying claim tokens without a nonzero mint/burn authority; INFToken.sol:16 has the identical guard.

#### G-39
`if (maxStaleness_ == 0 || fallbackPremiumBps_ >= BPS)` · `src/WstEthUsdOracle.sol:54` · Purpose: keep feed freshness finite/nonzero and fallback premium below 100 percent.

#### G-40
`if (feedDecimals > 18)` · `src/WstEthUsdOracle.sol:58` · Purpose: keep cached decimal normalization within the WAD exponent range.

#### G-41
`if (stEthPerWstEth == 0)` · `src/WstEthUsdOracle.sol:77` · Purpose: require a nonzero collateral exchange rate before conversion.

#### G-42
`if (fallbackPrice == 0)` · `src/WstEthUsdOracle.sol:89` · Purpose: reject a zero fallback quote before premium-adjusted redemption pricing.

#### G-43
`if (wstEthUsd == 0)` · `src/WstEthUsdOracle.sol:80` · Purpose: reject a primary quote rounded to zero.

#### G-44
`if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp)` · `src/WstEthUsdOracle.sol:102` · Purpose: exclude invalid answers and absent or future feed timestamps.

#### G-45
`if (roundId == 0 || answeredInRound < roundId)` · `src/WstEthUsdOracle.sol:103` · Purpose: reject incomplete or invalid primary feed rounds.

#### G-46
`if (block.timestamp - updatedAt > maxStaleness)` · `src/WstEthUsdOracle.sol:105` · Purpose: enforce the router's immutable freshness limit on every primary read.

#### G-47
`if ( wstETH_ == address(0) || weth_ == address(0) || usdc_ == address(0) || address(factory_) == address(0) || address(wstEthWethPool_) == address(0) || address(wethUsdcPool_) == address(0) || wstETH_ == weth_ || weth_ == usdc_ || wstETH_ == usdc_ || twapWindow_ < 30 minutes || twapWindow_ > 1 days || minWstEthWethLiquidity_ == 0 || minWethUsdcLiquidity_ == 0 )` · `src/UniswapV3TwapOracle.sol:62` · Purpose: bind distinct nonzero assets/pools and bounded observation window with nonzero liquidity thresholds.

#### G-48
`if ( IERC20Metadata(wstETH_).decimals() != 18 || IERC20Metadata(weth_).decimals() != 18 || IERC20Metadata(usdc_).decimals() != 6 )` · `src/UniswapV3TwapOracle.sol:68` · Purpose: bind quote scaling to 18-decimal wstETH/WETH and 6-decimal USDC.

#### G-49
`if (ticks.length != 2 || secondsPerLiquidity.length != 2 || secondsPerLiquidity[1] <= secondsPerLiquidity[0])` · `src/UniswapV3TwapOracle.sol:103` · Purpose: require usable two-endpoint observations and increasing liquidity cumulatives.

#### G-50
`if (harmonicLiquidity < minimumLiquidity || pool.liquidity() < minimumLiquidity)` · `src/UniswapV3TwapOracle.sol:109` · Purpose: require both time-weighted and current pool depth before accepting a quote.

#### G-51
`if (roundedTick < TickMath.MIN_TICK || roundedTick > TickMath.MAX_TICK)` · `src/UniswapV3TwapOracle.sol:117` · Purpose: keep the averaged tick inside the imported TickMath range.

#### G-52
`if ( pool.factory() != address(factory_) || pool.token0() != token0 || pool.token1() != token1 || factory_.getPool(token0, token1, pool.fee()) != address(pool) )` · `src/UniswapV3TwapOracle.sol:142` · Purpose: bind each fallback pool to the configured factory and token identities.

#### G-53
`if ( address(wstETH_) == address(0) || address(stEthUsdFeed_) == address(0) || address(fallbackOracle_) == address(0) )` · `src/WstEthUsdOracle.sol:50` · Purpose: bind the immutable router to nonzero primary, collateral-rate, and fallback dependencies.

#### G-54
`if (address(fallbackOracle_).code.length == 0)` · `src/WstEthUsdOracle.sol:55` · Purpose: ensure the fallback target contains executable code during construction.

#### G-55
`if (fallbackPrice == 0)` · `src/WstEthUsdOracle.sol:60` · Purpose: require a usable fallback quote during router construction.

#### G-56
`if (requestEpoch.requestedInf == 0)` · `src/NaNReserve.sol:280` · Purpose: prevent maturity queries from reporting an unopened cohort as scheduled.

#### G-57
`if (debt != 0)` · `src/NaNReserve.sol:652` · Purpose: forbid a zero-junior-supply bootstrap quote while senior debt exists.

#### G-58
`if (usdcAmount == 0 || usdcAmount > type(uint256).max / USDC_TO_WAD)` · `src/UniswapV3TwapOracle.sol:94` · Purpose: reject a zero or unscalable final fallback quote before USD normalization.

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Conservation` · On-chain: **Yes**

> NaN total supply equals the sum of all nonzero-address NaN balances.

**Derivation** — Δ-pair: `NaNToken.sol:20–27` resolves `_mint` / `_burn` to equal supply and balance increments/decrements; inherited `ERC20._update` (`lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol:176–201`) pairs +value supply/+value recipient for mint and −value sender/−value supply for burn, while transfers pair sender −value with recipient +value. All balance/supply writes use this single inherited helper; NaNToken overrides no writer.

**If violated** — Senior debt measurement and holder balances would diverge.

#### I-2

`Conservation` · On-chain: **Yes**

> INF total supply equals the sum of INF balances, including tokens escrowed at the reserve.

**Derivation** — Δ-pair: `INFToken.sol:20–27` resolves the same inherited `_update` pairs as I-1. Escrow transfers do not change supply; only reserve-authorized mint and burn reach supply-changing branches. All writers are those inherited branches.

**If violated** — NAV denominators and withdrawal allocation would cease to represent outstanding junior shares.

#### I-3

`Bound` · On-chain: **Yes**

> The stored parameters always satisfy `0 < targetDebtRatioBps < maxDebtRatioBps < 10_000`.

**Derivation** — guard-lift: `if (targetBps == 0 || targetBps >= maxBps || maxBps >= BPS)` (`NaNReserve.sol:231`) guards the sole assignments to `targetDebtRatioBps` and `maxDebtRatioBps`. The constructor and `setDebtRatios` both call this helper; neither parameter has another writer. This constrains parameter ordering, not the live market ratio.

**If violated** — Withdrawal capacity and recovery boundary arithmetic would lose their ordered policy inputs.

#### I-4

`Bound` · On-chain: **Yes**

> Stored mint and redemption fee rates remain in `[0, 1_000]` basis points.

**Derivation** — guard-lift: `if (mintBps > MAX_FEE_BPS || redeemBps > MAX_FEE_BPS)` at `NaNReserve.sol:241`; sole writes are 242–243 through constructor 161 or setter 176–177. Unsigned storage supplies the lower bound.

**If violated** — Senior fee subtraction could exceed the intended cap.

#### I-5

`Bound` · On-chain: **Yes**

> The future-cohort withdrawal delay stays between one and thirty days.

**Derivation** — guard-lift: `if (newDelay < MIN_INF_WITHDRAWAL_DELAY || newDelay > MAX_INF_WITHDRAWAL_DELAY)` at `NaNReserve.sol:192`; every write is declaration/default 87 (three days) or guarded setter 196. Cohort maturity itself is a separate snapshot (I-8).

**If violated** — New cohort schedules would violate the advertised bounded waiting policy.

#### I-6

`Bound` · On-chain: **Yes**

> The next-effective batching duration stays between one hour and seven days.

**Derivation** — guard-lift: `if (newLength < MIN_INF_WITHDRAWAL_EPOCH || newLength > MAX_INF_WITHDRAWAL_EPOCH)` at `NaNReserve.sol:203`; every duration write is default 89 (one day) or setter 210. Schedule anchor writes at 208–209 do not alter the duration bound.

**If violated** — Epoch arithmetic could use an unsupported duration or zero divisor.

#### I-7

`Bound` · On-chain: **Yes**

> The configured halving period for future recovery episodes stays between one hour and thirty days.

**Derivation** — guard-lift: `if (newPeriod < MIN_RECOVERY_HALVING_PERIOD || newPeriod > MAX_RECOVERY_HALVING_PERIOD)` at `NaNReserve.sol:182`; all writes are default 78 (one day) and guarded setter 186. Episode copies at 680 use this validated value.

**If violated** — Recovery elapsed-time division and issuance decay would use unsupported policy inputs.

#### I-8

`Temporal` · On-chain: **Yes**

> An opened cohort keeps its maturity despite later delay or epoch changes.

**Derivation** — NatSpec: `NaNReserve.sol:86` — "Delay for newly opened INF withdrawal cohorts; existing cohorts keep their maturity." The sole maturity write is 450, guarded by first-open `address(requestEpoch.token) == address(0)` at 448 and paired with nonzero token assignment at 449; no path clears that token. Setters write only future delay and schedule at 196,208–210; settlement and expiry read the stored maturity at 467–492.

**If violated** — Governance could change already-promised settlement and expiry times.

#### I-9

`StateMachine` · On-chain: **Yes**

> Each opened cohort transitions from unsettled to exactly one terminal settled outcome, by settlement or expiry; it never returns to unsettled.

**Derivation** — edge: `settled == false` checked at `NaNReserve.sol:466` → `settled = true` at 478, or false checked at 491 → true at 494. All settled-field writes are these two assignments; there is no reset. Outcome fields are written only during successful settlement at 479–480.

**If violated** — Repeated settlement could repeat burning or collateral earmarking.

#### I-10

`Conservation` · On-chain: **Yes**

> New requests append disjoint intervals to the cohort's historical requested total; claiming removes a live request without rewriting that historical denominator.

**Derivation** — Δ-pair: `NaNReserve.sol:454–456` stores start = prior requested total, raises a previously zero request amount by infIn, and raises cohort requestedInf by the same infIn. Zero/duplicate guards are at 441,447. The only other request writer deletes it at 521; cohort requestedInf is never reduced. Thus historical appended amounts sum to requestedInf, while the sum of remaining live requests can be smaller after claims.

**If violated** — Overlapping intervals or a changing denominator would invalidate the fixed payout allocation.

#### I-11

`Conservation` · On-chain: **Yes**

> Settled unclaimed collateral is excluded from live reserve backing until its claim is paid.

**Derivation** — NatSpec: `NaNReserve.sol:111` — "Settled withdrawal collateral is excluded from reserve backing until users claim it." Every earmark writer is settlement +collateralOut at 482 or claim −collateralOut at 522; getter 264 subtracts that value before all backing calculations. Claim effects precede outgoing transfer at 525. The physical-balance identity relies on the configured collateral retaining ordinary transfer semantics.

**If violated** — The same collateral could count as both senior backing and a fixed junior payout.

#### I-12

`Ratio` · On-chain: **Yes**

> Across all requests of a settled cohort, prefix-difference allocations sum exactly to its filledInf and collateralOut, regardless of claim order.

**Derivation** — NatSpec: `NaNReserve.sol:511–512` — "Each request owns a disjoint interval of the epoch. Difference-of-prefixes distributes every unit exactly without a first/last claimant advantage." Formulas at 514–517 are floor(end * total / requestedInf) − floor(start * total / requestedInf). Historical intervals in I-10 partition `[0, requestedInf)`; epoch totals are fixed before claims at 478–482 and never rewritten. Telescoping gives exact aggregate totals, including partial fills and zero-valued individual allocations.

**If violated** — Allocation dust or claim-order dependence would prevent exact aggregate conservation.

#### I-13

`Ratio` · On-chain: **Yes**

> The recovery floor affects INF issuance only; it does not replace actual backing, senior debt, residual NAV, or withdrawal entitlement.

**Derivation** — Spec-stated global property: `RECAPITALIZATION.md:21–23` — "The floor is only an issuance price, never a collateral valuation, senior debt adjustment, guaranteed market price, or INF withdrawal entitlement." **(per spec)** Verified by funding formula 427–429,655–660 versus residual NAV at 296–333, settlement at 604–634, and senior redemption at 579–587 in `NaNReserve.sol`; only recovery struct assignment/deletion at 687,690 persists the episode.

**If violated** — An issuance policy could be mistaken for backing or a guaranteed redemption value.

#### I-14

`StateMachine` · On-chain: **Yes**

> Recovery is an observed episode: start only while inactive, retain its initial clock while active, and clear only on zero supply or an observed ratio-and-NAV recovery.

**Derivation** — edge: inactive `initialPriceUsd == 0` at `NaNReserve.sol:686` → assign episode at 687; active at 689 → delete at 690 only when `_recoveryAt` returns zero. Callee branches at 665–680 require zero supply or both ratio ≤ snapshotted exit and NAV ≥ decayed floor to return zero. All persistent recovery writes are 687 and 690; a new episode can begin only after an observed clear.

**If violated** — An active episode could restart its decay clock or disappear before its stated exit conditions.

#### I-15

`Temporal` · On-chain: **Yes**

> Within a fixed active episode, the issuance floor remains at least one price wei and decreases monotonically as chain time advances.

**Derivation** — Temporal: `NaNReserve.sol:697–705` uses elapsed = block.timestamp − episode.startedAt, halvings = elapsed / episode.halvingPeriod, returns one for halvings ≥256, and otherwise max(1, ceil((initialPriceUsd >> halvings) * (2T − elapsed % T) / (2T))). Start and T are stored once per episode (I-14/I-16); no wall-time suspension is implemented during oracle outages. No claim of continuously observed distress is made.

**If violated** — Funding could face zero pricing or an unexpected increase within the same episode.

#### I-16

`Ratio` · On-chain: **Yes**

> An active recovery episode preserves its initial price, start time, halving period, and exit ratio despite later configuration changes.

**Derivation** — Ratio extraction: `NaNReserve.sol:674–680` computes boundaryEquity = ceil(debt * (BPS − maxDebtRatioBps) / maxDebtRatioBps); initialPrice is WAD if debt = 0, otherwise max(1, ceil(boundaryEquity * WAD / supply)), then copies timestamp, configured period, and maximum ratio into Recovery. Funding calls this on pre-deposit reserve/debt/supply at 421–426; only initial assignment 687 or whole deletion 690 writes persistent episode state. Setters 186,234–236 never rewrite a retained episode.

**If violated** — Parameter updates or deposits could retroactively alter the active issuance schedule.

#### I-17

`StateMachine` · On-chain: **Yes**

> One immutable INF token and the namespace juniorSeries = 1 survive every recovery episode.

**Derivation** — NatSpec: `NaNReserve.sol:64` — "Permanent junior token; recapitalization dilutes, never replaces, existing INF." Immutable assignment occurs only at constructor 164; constant namespace is 67. All junior issuance/burning targets that token at 432,453,481, and its reserve authority is immutable at `INFToken.sol:13,17`. No replacement assignment exists.

**If violated** — Existing or queued junior holders could lose the intended permanent-token continuity.

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes**

> Reserve senior liabilities equal the current NaN token supply, including after holder transfers.

**Caller side** — `NaNReserve.sol:292–294,544–556,573–591` reads supply for debt, then prices and gates senior operations against it; there is no separate debt counter.

**Callee side** — `NaNToken.sol:20–27` authorizes only reserve supply changes, resolved to the paired writes in I-1; inherited holder transfers preserve supply.

**If violated** — Debt/risk calculations would omit or invent senior liabilities.

#### X-2

On-chain: **Yes**

> Only the immutable reserve can change the supply of either production claim token.

**Caller side** — `NaNReserve.sol:163–164` passes its own address to each token constructor; supply calls occur at 432,481,556,591.

**Callee side** — `NaNToken.sol:13–27` and `INFToken.sol:13–27` assign the nonzero reserve once and check msg.sender in every public mint/burn entry point; neither token has another public supply writer.

**If violated** — Claims could be created or destroyed outside the reserve accounting paths.

#### X-3

On-chain: **Yes**

> Queued INF remains in the NAV denominator until the filled amount is burned at settlement; refunds transfer existing shares rather than minting new ones.

**Caller side** — `NaNReserve.sol:453,481,524,605` escrows shares, snapshots supply before settlement burn, and later refunds unfilled shares.

**Callee side** — `INFToken.sol:9,20–27` inherits supply-conserving ERC20 transfers and exposes only reserve-gated supply-changing helpers; resolved writes are those of I-2.

**If violated** — Queue participants could be omitted from residual-equity pricing or receive newly created refund shares.

#### X-4

On-chain: **No**

> The selected price router and fallback adapter value the exact collateral asset held by the reserve.

**Caller side** — `NaNReserve.sol:158,219–226,251–264` fixes collateral but allows router replacement after only nonzero/code/positive-price checks; no router-asset identity comparison exists at any oracle assignment (159/226).

**Callee side** — `WstEthUsdOracle.sol:65–70` separately binds wstETH and fallback during construction; `UniswapV3TwapOracle.sol:73–84` independently binds its asset/pool addresses. Neither constructor ties those choices to the reserve collateral, and the router checks fallback price rather than fallback asset identity at 55–63.

**If violated** — Nominal USD quotes may describe a different asset even though interface and positivity checks pass. This is an unvalidated configuration assumption, not a demonstrated misdeployment.

#### X-5

On-chain: **No**

> A risk-band update preserves the currently available mint/withdrawal capacity and the current maximum-band health classification.

**Caller side** — `NaNReserve.sol:318–324,551–553,620–634` reads current max/target parameters when classifying health or executing capacity checks, including settlement of already-open cohorts.

**Callee side** — `NaNReserve.sol:230–237` writes all three parameters after ordering checks only, through constructor 160 or owner setter 172; it does not compare new values against existing reserve/debt or opened cohorts.

**If violated** — An existing holder's capacity or health classification can change without a balance movement. This is a diagnostic continuity property, explicitly not promised: settlement uses current settings and bands are action limits (`DESIGN.md:22,55`; per spec).

## 4. Economic Invariants

#### E-1

On-chain: **Yes**

> All successful claims of a terminal cohort distribute its entire fixed collateral allocation and return exactly its aggregate unfilled INF; expiry returns all requested INF.

**Follows from** — [I-2](#i-2) + [I-9](#i-9) + [I-10](#i-10) + [I-12](#i-12) + [X-3](#x-3). Request deletion prevents repeat claims; prefix sums telescope; each refund equals request amount − filled allocation (`NaNReserve.sol:519–525`). Expiry fixes zero fill/output at the initially zero fields with settled = true at 494. Completion assumes every eligible holder eventually claims; no claimant can force another holder to claim.

**If violated** — Fixed cohort value could remain undistributable or be distributed more than once.

#### E-2

On-chain: **Yes**

> Changing the recovery issuance floor does not itself create senior backing or grant junior redemption value: settled claims and senior liabilities remain separate from issuance-price policy.

**Follows from** — [I-11](#i-11) + [I-13](#i-13) + [I-17](#i-17) + [X-1](#x-1) + [X-3](#x-3). Settlements use residual backing and current senior supply; the permanent token remains outstanding during dilution. This does not guarantee positive INF NAV or future capital arrival.

**If violated** — Issuance price could be confused with an enforceable residual-value entitlement.

#### E-3

On-chain: **No**

> The nominal USD senior/junior accounting is tied to the actual configured collateral denomination for every permitted router selection.

**Follows from** — [I-1](#i-1) + [I-2](#i-2) + [I-3](#i-3) + [X-4](#x-4). Supply and ordered arithmetic are enforced, while asset identity binding is not; nominal accounting alone therefore cannot establish this denomination property. No claim about current live market prices or a deployed configuration is made.

**If violated** — Supply conservation and ratio checks would not by themselves establish correctly denominated dollar backing.
