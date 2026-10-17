# X-Ray Report

> NaN Protocol | 892 nSLOC enumerated | fc2b480 (`main`) | Foundry / Solidity 0.8.24 | 12/10/26

Pre-audit structural assessment of the current working tree, which matched HEAD when the scan began. Skill: Pashov x-ray v2, installed from `pashov/skills@92b0ea6786e6c210bc9a839e4813d50876c1c550`. Investigation pointers below are not confirmed vulnerabilities or a completed security audit.

## 1. Protocol Overview

**What it does:** A pooled wstETH reserve backs senior USD-denominated NaN and permanent junior INF equity, with delayed junior exits and same-token recovery funding.

- **Users:** NaN minters/redeemers and INF capital providers/withdrawers.
- **Core flow:** Deposit collateral to mint a senior or junior claim; burn senior claims immediately or escrow junior claims for cohort settlement and pull claims.
- **Key mechanism:** Primary-priced risk bands, residual NAV, a decaying recovery issuance floor, and redemption-only TWAP fallback.
- **Token model:** NaN supply measures dollar liabilities; permanent INF represents residual equity and absorbs dilution during recovery.
- **Admin model:** Two-step owner can rotate the complete oracle router and change five bounded parameter groups immediately; governance delay is external to the reserve.

See the [architecture diagram](architecture.svg), [entry-point map](entry-points.md), and [invariant catalog](invariants.md). Diagram structure and SVG syntax were validated; a raster preview was unavailable in this environment.

### Contracts in Scope

| Subsystem | Key contracts | nSLOC | Role |
|-----------|---------------|------:|------|
| Reserve, withdrawal queue, recovery | `NaNReserve` | 572 | Holds collateral, gates issuance, settles cohorts, records recovery episodes |
| Senior and junior claims | `NaNToken`, `INFToken` | 40 | ERC-20 / ERC-2612 claims; reserve-only supply changes |
| Primary router and fallback adapter | `WstEthUsdOracle`, `UniswapV3TwapOracle` | 209 | Validated feed conversion and two-pool TWAP redemption pricing |
| **Production scope total** | **5 contracts** | **821** | Protocol-authored production implementations |

Enumeration counted 892 nSLOC across ten `.sol` files: 821 production nSLOC, 62 local simulator nSLOC, and 9 interface nSLOC. The three `src/local/` simulators were inspected to confirm their development purpose and excluded from production attack-surface and invariant counts. Vendored dependencies, deployment tooling, UI, and Python models are contextual inputs rather than fully reviewed scope.

The `series` namespace remains active in withdrawal storage and the UI, is explicitly documented, and is fixed at one; it was not classified as dead backwards-compatibility code (`NaNReserve.sol:66–67,107–110,440–458`).

### How It Fits Together

The core trick: senior debt is paid before junior residual equity, while recovery funding issues more of the existing INF token instead of replacing it.

### Junior capital and recovery

```text
User → NaNReserve.fund()
       ├─ primary price + existing debt/reserve/INF snapshots
       ├─ _syncRecovery() → _fundingQuote(NAV, decayed floor)
       ├─ _pullExact() → wstETH.transferFrom(user, reserve)
       └─ INFToken.mint(recipient) → post-funding recovery observation
```

*Issuance uses the pre-deposit snapshots; exact collateral receipt is verified before minting (`NaNReserve.sol:421–433`).*

### Senior issuance

```text
User → NaNReserve.mint()
       ├─ require active INF; quote NaN less retained fee
       ├─ check post-trade maximum debt ratio
       ├─ _pullExact() → wstETH.transferFrom(user, reserve)
       └─ NaNToken.mint(recipient)
```

*Fees stay in the reserve; the ratio check occurs before the transfer and senior mint (`NaNReserve.sol:540–557`).*

### Junior exit

```text
INF holder → requestDefund() → INFToken.transferFrom(holder, reserve)
             └─ fixed cohort maturity; append disjoint request interval
Caller → settleDefundEpoch() → quote current safe capacity
          ├─ INFToken.burn(reserve, filled amount)
          └─ earmark collateral outside reserve backing
Holder → claimDefund() → delete request and reduce earmark
          ├─ refund unfilled INF to holder
          └─ send fixed collateral to recipient
```

*Settlement, not the request, fixes value; missed windows permit oracle-free expiry and refund (`NaNReserve.sol:440–528`).*

### Senior redemption

```text
NaN holder → NaNReserve.redeem()
              ├─ primary price, or premium-adjusted fallback
              ├─ $1 quote when solvent; pro-rata quote when underwater
              ├─ NaNToken.burn(holder)
              └─ wstETH.transfer(recipient)
```

*The final underwater redeemer receives remaining backing, excluding settled withdrawal collateral; fallback redemption skips recovery observations (`NaNReserve.sol:573–595`).*

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Stablecoin** with **residual-share vault** characteristics.

Senior collateralized mint/redeem dominates the architecture; INF adds share pricing, donations, dilution, and delayed exits. There are no strategies, collateralized user loans, liquidation functions, staking validators, or embedded DAO voting.

### Actors & Adversary Model

| Actor | Trust level | Capabilities |
|-------|-------------|--------------|
| Reserve authorizer / `owner()` | Trusted for price source and risk policy | Six immediate configuration entry points plus ownership nomination; no embedded timelock or multisig enforcement |
| `pendingOwner()` | Bounded by current-owner nomination | May accept ownership immediately; two-step transfer supplies no time delay |
| NaN holder / minter | Bounded by holdings, collateral receipt, slippage, and maximum band | Mint and redeem with arbitrary recipient; neither operation has an emergency pause |
| INF holder / funder | Bounded by issuance pricing and precision, holdings, cohort delay, and settlement capacity | Fund, escrow shares, and claim own request; queued shares retain dilution exposure |
| Recovery / settlement caller | Bounded by primary observation and cohort timestamps | Permissionlessly checkpoint, settle, or expire; cannot choose another holder's claim recipient |
| Immutable reserve address in each token | Trusted supply authority | Sole caller allowed to mint/burn NaN and INF; users retain ordinary transfers and permit approvals |

**Adversary ranking:**

1. **Oracle manipulator** — Primary collateral valuation and fallback market prices determine senior issuance and redemption terms.
2. **Compromised authorizer** — Price-source and risk-policy authority can materially change user economics despite bounded numeric settings.
3. **Recovery-timing arbitrageur** — Permanent junior ownership and time-dependent issuance make distress observations economically significant.
4. **Strategic redeemer / withdrawal participant** — Cohort timing and finite residual capital reward careful transaction sequencing.
5. **Donation / first-capital participant** — Actual collateral balances influence residual share pricing and bootstrap behavior.

See [entry-points.md](entry-points.md) for all 28 production state-changing entry points: 16 permissionless, 5 role-gated, and 7 admin-only, including inherited token and ownership functions.

### Trust Boundaries

- **Authorizer → reserve policy** — Two-step ownership protects acceptance, while router replacement and risk settings take effect without an embedded delay (`NaNReserve.sol:168–211,219–244`).
- **Reserve → token supply** — Immutable caller checks confine mint/burn authority to the reserve (`NaNToken.sol:13–27`, `INFToken.sol:13–27`).
- **Oracle → monetary valuation** — Positive prices are required, but reserve configuration does not compare router asset identity against collateral (`NaNReserve.sol:219–226`; `WstEthUsdOracle.sol:65–70`).
- **Reserve → external collateral** — SafeERC20 and exact incoming balance deltas protect transfer accounting; the immutable token's outgoing behavior remains a deployment assumption (`NaNReserve.sol:592,726–730`).
- **Live backing → settled claims** — Earmarked collateral is excluded immediately and returned only through pull claims (`NaNReserve.sol:264,478–482,521–525`).

Git signal: the reserve changed in 11 source commits, and the heuristic scan marked 11 access-control and 13 oracle/pricing-related commits; these counts guide review priority rather than establish defects.

### Key Attack Surfaces

- **Recovery issuance and observation ordering** &nbsp;&#91;[I-14](invariants.md#i-14), [I-15](invariants.md#i-15), [I-16](invariants.md#i-16)&#93; — `NaNReserve.sol:421–433,663–705` deserves tracing across split deposits, healthy rebounds, and elapsed outage time.

- **Cohort escrow, settlement, and prefix allocation** &nbsp;&#91;[I-9](invariants.md#i-9), [I-10](invariants.md#i-10), [I-12](invariants.md#i-12), [E-1](invariants.md#e-1)&#93; — Check `NaNReserve.sol:453–525` across interleaved cohorts, partial fills, claims, and expiry.

- **Senior redemption and reserved backing** &nbsp;&#91;[I-11](invariants.md#i-11), [X-1](invariants.md#x-1)&#93; — Confirm `NaNReserve.sol:575–595` preserves claim segregation and conservative payouts at equality, insolvency, and final redemption.

- **Authorizer operational powers** &nbsp;&#91;[I-3](invariants.md#i-3), [I-4](invariants.md#i-4), [X-4](invariants.md#x-4), [X-5](invariants.md#x-5)&#93; — Review whole-router replacement and immediate band changes at `NaNReserve.sol:219–244`, including effects on already-open cohorts and existing debt.

- **Fallback denomination and liquidity assumptions** &nbsp;&#91;[G-42](invariants.md#g-42), [G-49](invariants.md#g-49), [G-50](invariants.md#g-50)&#93; — Trace the premium-adjusted quote at `WstEthUsdOracle.sol:88–90` and pool observations at `UniswapV3TwapOracle.sol:98–118`, including the fixed USDC/USD assumption.

- **Donations and depleted-reserve bootstrap** &nbsp;&#91;[I-11](invariants.md#i-11), [I-13](invariants.md#i-13), [I-17](invariants.md#i-17)&#93; — Inspect balance-based accounting and no-supply/no-equity branches at `NaNReserve.sol:263–264,646–680` without assuming every transfer was a funding operation.

- **Withdrawal schedule changes** &nbsp;&#91;[I-6](invariants.md#i-6), [I-8](invariants.md#i-8)&#93; — Verify boundary and maturity preservation around repeated governance updates at `NaNReserve.sol:202–211,269–274,448–450`.

There is no upgrade entry point or emergency pause in the production reserve. All user actions remain callable subject to their ordinary guards; oracle rotation is the available dependency-recovery mechanism.

### Protocol-Type Concerns

- **Stablecoin precision** — Integer USD conversions, retained fee rounding, and equality-specific final-redemption behavior deserve paired boundary checks (`NaNReserve.sol:579–587,708–723`).
- **Residual-share precision** — Ordinary issuance uses exact equity/supply rather than a rounded token NAV, while floor pricing and settlement use separate rounding paths (`NaNReserve.sol:628–629,655–660`).

### Temporal Risk Profile

**Deployment and initialization:**

- Constructors atomically bind tokens to the reserve, while first funding remains public and collateral donations can precede initialization of junior supply (`NaNReserve.sol:163–164,263–264,651–653`).
- Fallback availability is checked during router construction, so full observation history and initial liquidity are launch dependencies (`WstEthUsdOracle.sol:55–63`).

**Market stress and liveness:**

- Missed settlement windows permit expiry rather than a late price-dependent payout; successful claims need no oracle and have no claim deadline (`NaNReserve.sol:467–469,488–525`).
- Debt-free junior settlement uses in-kind collateral and bypasses oracle availability, unlike debt-bearing settlement (`NaNReserve.sol:609–617`).

### Composability & Dependency Risks

> **Collateral / wstETH** — via `NaNReserve._pullExact()` and `WstEthUsdOracle.price()`
> - Assumes: genuine 18-decimal collateral, stable token transfer semantics, and a meaningful `stEthPerToken()` exchange rate.
> - Validates: collateral decimals once, exact incoming receipt, SafeERC20 success, and positive exchange rate.
> - Mutability: reserve address binding is immutable; target implementation/governance was not verified from a deployed instance.
> - On failure: affected operations revert; primary rate failure permits the configured redemption fallback.

> **Chainlink-compatible stETH/USD feed** — via `WstEthUsdOracle._readFeed()`
> - Assumes: the configured feed denominates one stETH in USD and remains economically accurate within its freshness window.
> - Validates: decimals ≤18, positive answer, nonzero/nonfuture timestamp, complete round, and `maxStaleness`.
> - Mutability: each router binds its feed immutably; authorizer may replace the whole router.
> - On failure: minting/funding/ordinary views fail; redemption tries fallback (`WstEthUsdOracle.sol:98–107`).

> **Uniswap v3 wstETH/WETH and WETH/USDC pools plus factory** — via `UniswapV3TwapOracle.price()`
> - Assumes: sustained pool prices are suitable valuation inputs and USDC represents one USD.
> - Validates: factory/token identities, 18/18/6 decimals, 30-minute–1-day window, observation shape, mean tick bounds, and minimum harmonic/current liquidity.
> - Mutability: pool references and thresholds are immutable per adapter; liquidity and market prices change externally.
> - On failure: fallback reverts and redemption fails closed when primary also fails (`UniswapV3TwapOracle.sol:62–145`).

**Unvalidated token assumptions:** Outgoing collateral must debit the reserve and credit recipients predictably; inbound transfer-fee rejection does not establish all future token behavior (`NaNReserve.sol:525,592,726–730`).

**Shared-state exposure:** Both fallback pools are public market resources; manipulation cost and correlation with other users were not measured, and protocol operations do not themselves swap through those pools.

## 3. Invariants

> Full catalog: **[invariants.md](invariants.md)** — 58 enforced guards, 17 single-contract invariants, 5 cross-contract invariants, and 3 economic invariants; 3 inferred properties are not enforced on-chain, including explicit diagnostic assumptions rather than proven bugs.

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | Describes operations, dependencies, safety properties, and prototype status |
| NatSpec | Present, sparse at function level | 66 tagged lines across 10 source files; bundled scanner's value 10 counts file-result rows, not annotations |
| Specification | Present | `DESIGN.md` (145 lines), `RECAPITALIZATION.md` (63 lines); recovery is explicitly an economic draft |
| Inline comments | Targeted | Explain exact-NAV issuance, prefix allocations, TWAP rounding, and rebound reset behavior |

Claims sourced from documents are marked **(per spec)** in the invariant catalog. The design expressly says risk bands are action limits, capital arrival is not guaranteed, and the withdrawal delay is not an economic guarantee (`DESIGN.md:22,59,102`; per spec). External deployment identities, live liquidity, oracle manipulation cost, and a timelocked authorizer remain unverified.

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test-directory Solidity files | 15, including 4 mock/helper files; 11 `.t.sol` files | Enumeration plus filename scan |
| Ordinary test functions | 118, including 7 stateless fuzz functions | Enumeration |
| Foundry stateful invariant functions | 11 | Corrected signature scan and successful runtime results |
| Production line coverage | **98.69% (452/458)** | Sum of five production source rows |
| Production branch coverage | **75.42% (89/118)** | Sum of five production source rows |
| Reserve line / branch coverage | 99.13% / 73.26% | `forge coverage` |
| Fallback adapter line / branch coverage | 98.18% / 55.56% | `forge coverage` |
| Runtime outcome | **128 passed, 0 failed, 1 skipped** | `forge coverage`, 11 suites |

Coverage completed successfully without the IR retry. Foundry's overall 91.34% line / 77.93% branch totals include deployment scripts and test helpers; production-only figures above avoid mixing those scopes. Coverage uses optimizer-disabled instrumentation rather than the configured optimized deployment build.

### Test Depth

| Category | Count | Evidence / scope |
|----------|------:|------------------|
| Deterministic unit and integration functions | 111 | 118 ordinary tests minus 7 fuzz tests; includes the skipped fork test |
| Stateless fuzz | 7 | Reserve, recovery, and withdrawal test signatures |
| Stateful fuzz (Foundry) | 11 | Each invariant ran 256 campaigns / 16,384 handler calls; configured depth 64 |
| Fork | 1 detected, 1 skipped | `NAN_MAINNET_RPC_URL` was unavailable; current candidate pools were not exercised |
| Formal verification | 0 detected | No Certora specs/configs, Halmos functions/configs, or HEVM proofs |

**Enumeration correction:** The bundled scanner reported zero Foundry invariants because it matches `invariant_`; this repository names them `invariantName`. Signature checks found eleven and coverage executed all eleven. Existing stateful fuzz must not be reported as absent.

### Gaps

- No formal-verification category was detected for the reserve arithmetic and multi-step queue/recovery lifecycle.
- No Echidna/Medusa harness or configuration was detected; a working Foundry stateful suite already exists.
- The live fork test was skipped, and fallback branch coverage is 55.56%; neither mock-based coverage nor this report establishes live-market oracle resilience.

## 6. Developer & Git History

> Analyzed branch: `main` at `fc2b48058c5c5e510841385b464c809a1801666b`. Repo shape: `normal_dev` — 28 reachable commits, 14 source-touching commits, 19-day development span; other branches were not analyzed.

### Contributors

| Git author identity | Commits | Source lines (+/−) | Share of source additions |
|---------------------|--------:|-------------------:|--------------------------:|
| Ste | 27 | +1,014 / −414 | 64.59% |
| Ste H | 1 | +556 / −0 | 35.41% |

These are two author names, not evidence of two independent humans or reviewers; the initial import accounts for the second identity's visible contribution.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Author identities | 2 | Independent review cannot be determined from author names |
| Merge commits | 7/28 (25%) | Branch integration is visible; review quality is not established |
| Development dates | 2026-09-21 → 2026-10-10 | 19-day span |
| Recent source commits | 14 | Entire source history lies in the script's 30-day window relative to latest commit |
| Test co-change rate | 78.6% (11/14) | File co-modification in source commits, not code coverage |
| Source commits without test-file changes | 3 | Includes formatting/docs/build work; absence of co-change is not absence of tests |

### File Hotspots

| File | Source-touching commits | Note |
|------|-----------------------:|------|
| `src/NaNReserve.sol` | 11 | Dominant current implementation and lifecycle review target |
| `src/WstEthUsdOracle.sol` | 4 | Price-source and fallback boundary |
| `src/INFToken.sol` | 3 | Permanent junior token semantics |
| `src/NaNToken.sol` | 2 | Senior supply authority |
| Removed `src/ERC20.sol`, `ReentrancyGuard.sol`, math/transfer helpers | 2 each | Historical paths; current implementations use OpenZeppelin |

### Security-Relevant Commits

Scores are heuristic review priorities based on message, structural diff, and source domains; feature/import commits can score highly and are not confirmed fixes or bugs.

| SHA | Date | Subject | Score | Current-branch review context |
|-----|------|---------|------:|-------------------------------|
| `02e571b` | 2026-09-21 | Harden recapitalization and bootstrap invariants | 13 | Active INF check and equality-specific final senior redemption remain visible |
| `d998bb6` | 2026-09-27 | Make INF withdrawal batching epochs configurable | 12 | Anchored schedule and next-boundary updates |
| `22948ee` | 2026-09-25 | Governed risk bands and withdrawal queue | 11 | Owner setters, earmarks, settlement and pull claims |
| `647df28` | 2026-09-21 | Complete NaN protocol | 11 | Dependency and token-accounting consolidation |
| `aa640ee` | 2026-10-01 | Reset recovery on healthy rebound with restored NAV | 10 | Active recovery snapshots the maximum exit ratio and checks NAV against floor |
| `aa1f10b` | 2026-09-21 | Restore default build compatibility | 10 | Reserve arithmetic organization; no same-commit test-file change |
| `8a21edd` | 2026-09-21 | Initial commit | 10 | Initial import; high structural score is not a bug-fix claim |
| `73e9879` | 2026-09-27 | Permanent INF with decaying issuance floor | 9 | Recovery pricing and snapshots |
| `d38ac38` | 2026-09-22 | Immutable oracle fallback for redemption | 9 | Primary/fallback separation |
| `e0ecdd3` | 2026-10-03 | Use fund for all INF deposits | 8 | Current ABI has `fund`, with no `recapitalize` entry point |

### Dangerous Area Evolution

| Heuristic security area | Commits | Main current paths |
|-------------------------|--------:|--------------------|
| Oracle / pricing | 13 | Reserve, primary router, TWAP adapter |
| Fund flows | 12 | Reserve, collateral transfer and claim paths |
| Access control | 11 | Reserve owner and token reserve checks |
| State machines | 11 | Withdrawal and recovery lifecycle |
| Signature keyword matches | 11 | Heuristic over broad diffs; actual permit implementation is inherited OpenZeppelin |

### Dependencies and Technical Debt

All three dependencies are pinned standard submodules: forge-std `8e40513`, OpenZeppelin `c64a1ed` (lockfile v5.4.0), and Uniswap v4 core `46c6834` (TickMath used for v3 tick decoding). No internalized current Solidity libraries or TODO/FIXME/HACK markers were detected. The scanner's generic Uniswap label and pragma-mismatch notes were not treated as evidence of a fork or changed upstream logic.

### Security Observations

- **Concentrated maintenance** — One author identity wrote 27/28 commits, while independent peer-review evidence remains undetermined.
- **Recent production semantics** — Permanent-INF recovery and unified funding are current-branch code; retired series-replacement paths are absent.
- **Review signal limits** — Co-change rates, merge counts, and keyword scores measure repository activity rather than security assurance.
- **Late-window limits** — The 30-day window contains all source development and does not independently establish an unusual pre-audit rush.

### Cross-Reference Synthesis

- **Reserve concentration** — Eleven modifications and the queue/recovery surfaces concentrate review on `NaNReserve` and [I-8 through I-16](invariants.md#i-8).
- **Recovery history** — Current maximum-ratio exit semantics align with the persisted episode analysis in [I-14](invariants.md#i-14).
- **Oracle history** — Primary/fallback work and authorizer rotation align with the asset-binding assumption in [X-4](invariants.md#x-4).

## X-Ray Verdict

**FRAGILE** — Tests and specifications are substantial, but the reserve embeds no timelock for immediate authorizer actions; the source tree alone does not establish a deployed timelocked owner.

Tier calculation: Tests **HARDENED** (unit + stateless fuzz + stateful invariants), Docs **HARDENED** (NatSpec + specification), Access Control **FRAGILE** (defined roles without embedded operational delay); no security-critical debt markers trigger a further downgrade. This is a structural readiness tier, not a finding of exploitability.

**Structural facts:**

1. Five production contracts contain 821 nSLOC; complete enumeration counts 892 including local simulators and interfaces.
2. Twenty-eight production state-changing entry points comprise 16 permissionless, 5 role-gated, and 7 admin-only functions.
3. Fifteen test-directory Solidity files contain 118 ordinary test functions and 11 stateful invariant functions.
4. Coverage ran 128 tests successfully with one skipped fork test; production coverage is 98.69% of lines and 75.42% of branches.
5. The reserve has two-step ownership, six immediate configuration entry points, and no embedded upgrade, timelock, or pause implementation.
