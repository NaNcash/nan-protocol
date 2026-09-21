# NaN v0 design

NaN v0 is a clean-room reimplementation of the core economic idea behind USM/FUM: one pooled volatile reserve split into a senior stable claim and a junior residual claim.

## Assets

- **wstETH** — sole reserve asset.
- **NaN** — senior token targeting 1 USD.
- **INF** — junior token owning residual reserve value and absorbing losses before NaN.

There are no user CDPs, liquidations, governance token, savings wrapper, privacy layer or secondary yield strategy in v0.

## Accounting

All accounting uses 18-decimal USD values.

```text
R = USD value of wstETH reserve
D = NaN total supply
E = max(R - D, 0)
S = INF total supply

INF NAV = E / S
```

wstETH staking rewards appear as an increase in the USD value of each wstETH token. NaN liabilities do not rebase, therefore reserve yield accrues to INF.

## Operations

### fund

Deposit wstETH and mint INF at current residual NAV. The first INF is bootstrapped at $1.

If the system is insolvent (`R <= D`), v0 deliberately disables ordinary funding. A separate recapitalisation mechanism should be designed rather than hiding recap auction policy inside the basic NAV formula.

### defund

Burn INF and withdraw its proportional residual value. The transaction is rejected if it would leave:

```text
D / R > MAX_DEBT_RATIO
```

The prototype uses 65%, equivalent to a minimum normal collateral ratio of about 153.85%.

### mint

Deposit wstETH and receive:

```text
NaN out = collateral USD value - mint fee
```

The full collateral stays in the reserve. The fee therefore accrues to INF. Minting is rejected if the post-trade debt ratio exceeds the configured maximum.

### redeem

While solvent, one NaN redeems for $1 of wstETH minus the redemption fee. The fee stays in the reserve for INF.

If the reserve becomes insolvent after a market gap, the redemption price automatically becomes:

```text
R / D dollars per NaN
```

and the explicit redemption fee is disabled. This makes redemptions pro-rata and prevents first redeemers from extracting $1 while leaving later holders with the loss.

## Oracle

The prototype oracle computes:

```text
wstETH/USD = ETH/USD * stETH-per-wstETH
```

using a Chainlink ETH/USD feed and the canonical `wstETH.stEthPerToken()` conversion rate.

This is intentionally only a prototype. A production oracle should additionally protect against a material stETH/ETH market depeg, likely by valuing the collateral at the lower of protocol redemption value and a robust market-price reference.

## Fixed launch parameters

The reserve contract is ownerless and non-upgradeable. Parameters are immutable at deployment:

- maximum debt ratio;
- mint fee;
- redemption fee;
- collateral token;
- oracle.

This follows the minimalist/immutable spirit of USM while avoiding its older moving bid/ask state machine.

## Deliberately unresolved before production

1. **Recapitalisation while insolvent.** This is the largest missing economic component. USM used special FUM buy-price behaviour; NaN should model alternatives before selecting one.
2. **Oracle depeg protection.** `stEthPerToken()` alone is not a market-price guarantee.
3. **Launch/bootstrap procedure.** We need a clear initial INF funding target before NaN minting opens.
4. **Parameter selection.** 65% max debt ratio and 10 bp mint/redeem fees are prototype values, not recommendations.
5. **Formal invariants and external audit.** Required before any value is put at risk.
