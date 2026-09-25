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
- The immutable oracle uses a fresh direct stETH/USD feed multiplied by `stEthPerToken()` for normal operations. On primary failure, only NaN redemption uses a two-pool Uniswap v3 TWAP for wstETH/WETH and WETH/USDC, with an upward price premium that reduces collateral paid per NaN.
- The primary is checked for a positive answer, valid timestamp, staleness, and completed round. The TWAP requires a full observation window, canonical Uniswap pools, and minimum current and time-weighted liquidity in both pools; unavailable or thin pools halt redemption.
- Fee-on-transfer collateral is rejected, and only 18-decimal collateral is accepted.
- NaN and INF use OpenZeppelin ERC-20 and ERC-2612 Permit. Reserve transfers, full-precision math, and reentrancy protection also use OpenZeppelin Contracts.

See [DESIGN.md](DESIGN.md) for the accounting model and state transitions.

## Dependencies

- Foundry
- Solidity 0.8.24
- OpenZeppelin Contracts 5.4.0
- Uniswap v4 core TickMath (MIT-licensed library used to decode Uniswap v3 ticks)
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

Copy `.env.example` to `.env` and set the collateral, [direct Chainlink stETH/USD feed](https://data.chain.link/ethereum/mainnet/crypto-usd/steth-usd), Uniswap v3 factory, wstETH/WETH pool, WETH/USDC pool, and their token addresses for the target network. The deployment script creates the immutable TWAP adapter, router, and reserve. `STETH_USD_FEED` must quote one stETH in USD. The fallback treats one USDC as one USD, so a USDC premium above $1 could make redemption too generous.

On Ethereum mainnet, candidate pools are [wstETH/WETH 0.01%](https://www.geckoterminal.com/eth/pools/0x109830a1aaad605bbf02a9dfa7b0b92ec2fb7daa) and [WETH/USDC 0.05%](https://www.geckoterminal.com/eth/pools/0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640). Recheck the factory, token order, observation history, liquidity, and manipulation cost at deployment. A direct wstETH/USDC pool should not be substituted without its own depth analysis.

`TWAP_WINDOW` must be between 30 minutes and one day. Both `MIN_*_HARMONIC_LIQUIDITY` values are required; they are Uniswap liquidity units, not USD amounts. Set them from target-pool observations and economic stress tests. The router constructor calls the TWAP once, so deployment fails if the fallback is invalid at that moment.

`FALLBACK_PREMIUM_BPS` increases the fallback redemption conversion price, reducing the wstETH withdrawn per NaN. It is not a guarantee against manipulated pool prices or a USDC depeg. Check both source quotes and staleness limits against target-network conditions before deployment.

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

NaN deliberately has no governance, upgrade proxy, emergency pause, secondary yield strategy, privacy layer, or user CDPs. The immutable fallback keeps NaN redemption available after a primary feed failure if both Uniswap pools remain valid and liquid. A bad immutable parameter or dependency cannot be repaired in place.
