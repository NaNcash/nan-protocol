# NaN Protocol

NaN is an immutable, wstETH-backed stablecoin protocol with two claims on one reserve:

- **NaN** is the senior USD-denominated claim.
- **INF** is the junior residual claim. It absorbs collateral losses first and receives wstETH yield and protocol fees.

The implementation is feature-complete for this design, but it is **unaudited**. Do not deploy it with real value before independent economic review, smart-contract audits, oracle review, and parameter validation.

## Protocol operations

| Operation | Input | Output | Availability |
| --- | --- | --- | --- |
| `fund` | wstETH | INF at residual NAV | Fresh primary oracle and positive junior equity |
| `mint` | wstETH | NaN less mint fee | Fresh primary oracle, active INF, and debt ratio within the limit |
| `defund` | INF | wstETH at residual NAV | Fresh primary oracle and debt ratio within the limit |
| `redeem` | NaN | wstETH less redemption fee | Valid primary or fallback; pro rata and fee-free when insolvent |
| `recapitalize` | wstETH | New-series INF on value above the shortfall | Fresh primary oracle and zero junior equity |

The contracts are ownerless, non-upgradeable, and have immutable collateral, oracle, risk limit, and fees. There are no privileged minting, pausing, parameter-changing, or asset-withdrawal roles.

## Safety properties

- Minting and junior withdrawals cannot push debt above `maxDebtRatioBps`.
- Insolvent NaN redemption is pro rata, so early redeemers cannot take $1 while leaving later holders with the loss.
- An insolvency recapitalization retires the wiped-out INF series and must restore the configured healthy debt ratio. The new INF series represents the resulting residual equity at $1.
- The immutable oracle uses a fresh direct stETH/USD feed multiplied by `stEthPerToken()` for normal operations. On primary failure, only NaN redemption can use the independent wstETH/USD fallback, with an upward price premium that reduces collateral paid per NaN.
- The primary is checked for a positive answer, valid timestamp, staleness, and completed round. The fallback contract must perform its own freshness and market-integrity checks; a zero or reverting fallback halts redemption.
- Fee-on-transfer collateral is rejected, and only 18-decimal collateral is accepted.
- NaN and INF use OpenZeppelin ERC-20 and ERC-2612 Permit. Reserve transfers, full-precision math, and reentrancy protection also use OpenZeppelin Contracts.

See [DESIGN.md](DESIGN.md) for the accounting model and state transitions.

## Dependencies

- Foundry
- Solidity 0.8.24
- OpenZeppelin Contracts 5.4.0
- forge-std 1.11.0
- Python 3 for the dependency-free economic model

Dependencies are pinned as git submodules and in `foundry.lock`.

## Build and test

```bash
git submodule update --init --recursive
forge fmt --check
forge test -vv
forge build --sizes
forge lint
python3 model/simulate.py
python3 model/check_invariants.py
```

The Solidity suite includes unit, fuzz, oracle failure, insolvency lifecycle, fee-token rejection, and stateful invariant tests.

## Deployment

Copy `.env.example` to `.env` and set the collateral, [direct Chainlink stETH/USD feed](https://data.chain.link/ethereum/mainnet/crypto-usd/steth-usd), and independently validated fallback oracle addresses for the target network. `STETH_USD_FEED` must quote one stETH in USD. `FALLBACK_ORACLE` must implement `IPriceOracle.price()` and quote one whole wstETH in USD with 18 decimals. A fallback built from the same Chainlink feed is not independent. The deployment script does not supply a fallback implementation; choose and audit a live on-chain source or TWAP adapter before deploying. The fallback contract must be non-upgradeable to preserve the no-governance trust model.

`FALLBACK_PREMIUM_BPS` increases the fallback redemption conversion price, reducing the wstETH withdrawn per NaN. It is not a guarantee against a manipulated or badly configured fallback. Check both source quotes and staleness limits against target-network conditions before deployment.

Review every address and parameter independently, then simulate before broadcasting:

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

The sample defaults (65% maximum debt ratio and 10 bp mint/redemption fees) are test parameters, not an economic recommendation. A deployment must also establish an adequate initial INF buffer with `fund` before opening NaN minting to users.

## Integration notes

- Always pass a meaningful minimum output to state-changing calls. A zero minimum disables price/slippage protection.
- Use `redemptionCollateralPriceUsd()` to see the active redemption quote and whether fallback mode is in use. Ordinary reserve health and NAV views require the primary feed.
- Read `reserve.inf()` dynamically. Insolvency recapitalization changes the active INF token address and increments `juniorSeries`; retired INF has no claim on the reserve.
- Index `Recapitalized` events so applications can retire old INF markets and discover the new series.
- Direct wstETH transfers are donations to the reserve and do not mint claims.
- Oracle freshness remains a liveness dependency for minting and junior actions. NaN redemption uses the independent fallback during primary failure, but halts if both sources are invalid.

## Scope

NaN deliberately has no governance, upgrade proxy, emergency pause, secondary yield strategy, privacy layer, or user CDPs. The immutable fallback keeps NaN redemption available after a primary feed failure if the fallback remains valid. A bad immutable parameter or dependency cannot be repaired in place.
