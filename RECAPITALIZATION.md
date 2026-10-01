# Single-INF recapitalization draft

This branch replaces series retirement with dilution of one permanent INF token.
It is an economic-design draft, not a production-ready or audited release.

## Proposed pricing

- `fund` accepts incremental capital even with zero residual equity. `recapitalize`
  remains an insolvency-only convenience entry point using the same pricing.
- Bootstrap with no INF supply remains $1 per INF. Otherwise normal funding uses
  exact residual equity / supply (not a prematurely rounded per-token quote).
- A fresh primary observation above the maximum debt ratio starts a pricing
  episode. Its initial USD/INF floor is the NAV at the maximum-ratio boundary:
  `ceil(ceil(D * (BPS - max) / max) * WAD / S)`, at least one price wei.
- The initial floor is snapshotted per token, not recalculated after each deposit.
  An already-depleted debt-free pool with surviving INF starts at $1 instead.
- The floor halves each configured interval, interpolating linearly between
  halvings. Default: one day; authorizer bounds: one hour to 30 days. This is a
  deliberately simple piecewise-linear schedule, not USM's exponential curve.
  Use OpenZeppelin `Math.mulDiv` and integer shifts, not a new fixed-point library.
- Issue at the greater of real NAV and the decayed floor; never issue at zero.
  The floor is only an issuance price, never a collateral valuation, senior debt
  adjustment, guaranteed market price, or INF withdrawal entitlement.
- An episode ends only when the observed debt ratio is at/below its snapshotted
  maximum AND real NAV is at least the remaining floor (or INF supply is zero).
  This avoids dropping the price below its floor just because a small deposit
  crosses a ratio boundary, which would reward splitting a deposit. A rebound
  into the healthy band resets the clock even if the withdrawal target is not met.
- The interval and exit ratio are snapshotted. Parameter changes affect future
  episodes, never rewrite an existing episode's clock or initial price.

## Observation and integration

Anyone may checkpoint the primary oracle. Funding and other primary-priced
reserve actions also observe recovery. Observations are not continuous proof of
market conditions: an unobserved rebound cannot reset the clock. Elapsed wall
time, including oracle outages, counts after an episode starts. Fallback-only
redemption must neither start nor clear an episode and must remain available.

The existing withdrawal ABI keeps its `series` argument as a compatibility
namespace fixed at 1. INF itself is immutable; there is no replacement machinery.
Queued shares remain subject to dilution, and settled collateral stays excluded
from reserve backing. Three-day default withdrawals and senior redemption rules
are unchanged. The minimum debt ratio still caps funding; a single deposit no
longer needs to restore the target ratio.

## Review gates

Test flash crashes/rebounds, partial and full recapitalization, split deposits
(including recovery-boundary crossings), long decay, repeated episodes, stale
primary/fallback redemption, authorizer updates, withdrawal queues, depleted
reserves and rounding. Preserve accounting and senior-solvency invariants.

Economic review must address waiting for cheaper issuance, early contributors
absorbing the deficit before receiving positive NAV, potentially extreme
dilution, the initial floor/decay calibration, and future governance capture.
Neither this mechanism nor series replacement guarantees capital will arrive.

References: [original USM/FUM proposal, section E](https://jacob-eliosoff.medium.com/whats-the-simplest-possible-decentralized-stablecoin-4a25262cf5e8),
[USM implementation](https://github.com/usmfum/USM/blob/master/contracts/USM.sol),
[OpenZeppelin Math](https://docs.openzeppelin.com/contracts/5.x/api/utils#Math).
This draft borrows the same-token/declining-price principle, not USM's complete
pricing algorithm or its custom math library.
