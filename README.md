# NaN Protocol v0

Experimental, unaudited prototype of a minimalist wstETH-backed stablecoin.

NaN uses one pooled wstETH reserve split into two economic claims:

- **NaN** — senior $1 stablecoin claim.
- **INF** — junior residual claim that absorbs ETH/wstETH volatility and receives staking yield plus protocol fees.

The design is inspired by the senior/junior reserve concept explored by USM/FUM, but this repository is a clean-room implementation rather than a fork of the 2021 contracts.

## Core flow

```text
                         wstETH reserve
                               |
                +--------------+--------------+
                |                             |
              NaN                           INF
        senior $1 claim              junior residual claim
                                             |
                                  staking yield + fees
```

There are four core actions:

```text
fund     wstETH -> INF
mint     wstETH -> NaN
defund   INF    -> wstETH
redeem   NaN    -> wstETH
```

## Prototype parameters

The tests instantiate the system with:

- max debt ratio: **65%** (~153.85% minimum normal collateralisation)
- mint fee: **10 bps**
- redemption fee: **10 bps**

These are placeholders for simulation, not final monetary-policy parameters.

## Contracts

- `src/NaNReserve.sol` — reserve accounting and all four state transitions.
- `src/NaNToken.sol` — senior ERC-20.
- `src/INFToken.sol` — junior ERC-20.
- `src/WstEthUsdOracle.sol` — ETH/USD × stETH-per-wstETH prototype oracle.

## Run

With Foundry installed:

```bash
forge test -vv
python3 model/simulate.py
```

## Important limitations

This is not production code. In particular:

- insolvent INF recapitalisation is intentionally not implemented yet;
- the oracle needs a market-depeg guard before production;
- the ERC-20 implementation is intentionally minimal;
- no audit or formal verification has been performed;
- no privacy functionality exists in v0.

See `DESIGN.md` for the economic model and open design questions.
