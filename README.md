# NaN Protocol

NaN is an immutable, wstETH-backed stablecoin protocol with two claims on one reserve:

- **NaN** is the senior USD-denominated claim.
- **INF** is the junior residual claim. It absorbs collateral losses first and receives wstETH yield and protocol fees.

The implementation is feature-complete for this design, but it is **unaudited**. Do not deploy it with real value before independent economic review, smart-contract audits, oracle review, and parameter validation.

## Protocol operations

| Operation | Input | Output | Availability |
| --- | --- | --- | --- |
| `fund` | wstETH | INF at residual NAV | Positive junior equity |
| `mint` | wstETH | NaN less mint fee | Resulting debt ratio is within the limit |
| `defund` | INF | wstETH at residual NAV | Resulting debt ratio is within the limit |
| `redeem` | NaN | wstETH less redemption fee | Always; pro rata and fee-free when insolvent |
| `recapitalize` | wstETH | New-series INF on value above the shortfall | Zero junior equity |

The contracts are ownerless, non-upgradeable, and have immutable collateral, oracle, risk limit, and fees. There are no privileged minting, pausing, parameter-changing, or asset-withdrawal roles.

## Safety properties

- Minting and junior withdrawals cannot push debt above `maxDebtRatioBps`.
- Insolvent NaN redemption is pro rata, so early redeemers cannot take $1 while leaving later holders with the loss.
- An insolvency recapitalization retires the wiped-out INF series. Recapitalization capital first fills the senior shortfall; only the surplus mints the new INF series at $1.
- The oracle values stETH at the lower of 1 ETH and the stETH/ETH market feed, then applies `stEthPerToken()` and ETH/USD. Both market feeds must be fresh and valid.
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

Copy `.env.example` to `.env` and set the collateral and Chainlink-compatible feed addresses for the target network. `STETH_ETH_FEED` must quote one stETH in ETH; it is not a wstETH feed.

Review every address and parameter independently, then simulate before broadcasting:

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

The sample defaults (65% maximum debt ratio and 10 bp mint/redemption fees) are test parameters, not an economic recommendation. A deployment must also establish an adequate initial INF buffer with `fund` before opening NaN minting to users.

## Integration notes

- Always pass a meaningful minimum output to state-changing calls. A zero minimum disables price/slippage protection.
- Read `reserve.inf()` dynamically. Insolvency recapitalization changes the active INF token address and increments `juniorSeries`; retired INF has no claim on the reserve.
- Index `Recapitalized` events so applications can retire old INF markets and discover the new series.
- Direct wstETH transfers are donations to the reserve and do not mint claims.

## Scope

NaN deliberately has no governance, upgrade proxy, emergency pause, secondary yield strategy, privacy layer, or user CDPs. Operational simplicity reduces authority and attack surface, but it also means a bad immutable parameter or dependency cannot be repaired in place.
