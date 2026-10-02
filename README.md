# NaN Protocol

NaN is a non-upgradeable, wstETH-backed stablecoin protocol with two claims on one reserve:

- **NaN** is the senior USD-denominated claim.
- **INF** is the junior residual claim. It absorbs collateral losses first and receives wstETH yield and protocol fees.

This is an **unaudited prototype**. Do not deploy it with real value before independent economic review, smart-contract audits, oracle review, and parameter validation.

## Protocol operations

| Operation | Input | Output | Availability |
| --- | --- | --- | --- |
| `fund` | wstETH | Permanent INF at the greater of NAV and the recovery issuance floor | Fresh primary oracle; post-funding debt ratio at or above the minimum when debt exists; incremental insolvent funding allowed |
| `mint` | wstETH | NaN less mint fee | Fresh primary oracle, active INF, and post-mint debt ratio at or below the maximum |
| `requestDefund` | INF | A locked withdrawal request | One request per address and cohort; no oracle quote is fixed |
| `settleDefundEpoch` | Matured cohort | Claimable wstETH and any unfilled INF | After the cohort's snapshotted delay; fresh primary oracle and target debt-ratio limit when debt exists |
| `claimDefund` | Settled request | Fixed wstETH payout and unfilled INF | Oracle-free pull claim |
| `redeem` | NaN | wstETH less redemption fee | Valid primary or fallback; pro rata and fee-free when insolvent |
| `checkpointRecovery` | None | Persisted pricing-episode observation | Permissionless; fresh primary oracle required |

The reserve is non-upgradeable and has an OpenZeppelin two-step owner serving as its authorizer. The authorizer can replace the entire oracle router and update the ordered minimum, target, and maximum debt ratios, mint/redemption fees, INF withdrawal delay, batching epoch length, and recovery-price halving period for future episodes. It cannot mint tokens, pause user actions, withdraw collateral, change the collateral token, or rewrite the senior/junior claim rules. Ownership cannot be renounced. Use a timelocked governance contract as the authorizer in production; these powers can materially affect users.

## Safety properties

- With debt outstanding, INF funding cannot push `D/R` below `minDebtRatioBps`; bootstrap funding with no debt is uncapped. INF withdrawal settlement preserves `targetDebtRatioBps`, and minting preserves `maxDebtRatioBps`. The ratios must satisfy `0 < min < target < max < 10,000` basis points.
- INF withdrawals settle by cohort after the configured delay, initially three days, plus the remaining batching time. Governance can set the delay between one and 30 days and the batching epoch between one hour and seven days (initially one day). Epoch-length updates apply at the current epoch's closing boundary, preserving its ID and end time. Each cohort snapshots its maturity when its first request arrives, so later governance changes cannot shorten or extend pending requests. Each cohort has a one-day settlement window; an unsettled cohort expires and locked INF can be reclaimed. Settlement uses the then-current price, not the request-time price. Limited safe exit capacity is allocated pro rata within a cohort.
- Settled but unclaimed wstETH is excluded from reserve backing. Pending INF remains in total supply until its filled portion is burned at settlement.
- Insolvent NaN redemption is pro rata, so early redeemers cannot take $1 while leaving later holders with the loss.
- INF has one immutable address. Recapitalization dilutes existing holders rather than cancelling their claims, and need not restore solvency in one transaction. Recovery pricing starts on an observed breach of the maximum debt ratio, with a positive USD/INF issuance floor that halves every day by default (linear interpolation between halvings). It never changes actual senior debt, INF NAV, or withdrawal entitlements. Severe dilution and failure to attract funding remain possible.
- The initial oracle router uses a fresh direct stETH/USD feed multiplied by `stEthPerToken()` for normal operations. On primary failure, only NaN redemption uses a two-pool Uniswap v3 TWAP for wstETH/WETH and WETH/USDC, with an upward price premium that reduces collateral paid per NaN. The authorizer can deploy and select a new router if either source needs replacement.
- Both fees are authorizer-settable but capped at 1,000 basis points each. An insolvent redemption still has no explicit fee.
- The primary is checked for a positive answer, valid timestamp, staleness, and completed round. The TWAP requires a full observation window, canonical Uniswap pools, and minimum current and time-weighted liquidity in both pools; unavailable or thin pools halt redemption.
- Fee-on-transfer collateral is rejected, and only 18-decimal collateral is accepted.
- NaN and INF use OpenZeppelin ERC-20 and ERC-2612 Permit. Reserve transfers, full-precision math, and reentrancy protection also use OpenZeppelin Contracts.

See [DESIGN.md](DESIGN.md) for the accounting model and state transitions and [RECAPITALIZATION.md](RECAPITALIZATION.md) for the draft pricing specification and economic review gates.

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

## Local Anvil playground

This repository includes a loopback-only Anvil deployment and a small wallet-connected UI. It uses the **real NaNReserve and WstEthUsdOracle** with deliberately unsafe local mocks: a faucet-enabled 18-decimal wstETH token, a controllable 8-decimal stETH/USD primary feed, and a manually priced fallback. The mock token exposes `stEthPerToken`, so its value changes when you simulate staking yield. The healthy mock feed follows Anvil time to make multi-day time travel practical; use its stale/unavailable switches to test failure handling. None of these mocks is suitable for public or production deployment.

Requirements: Foundry (including `anvil` and `forge`), Node.js 20.19+ and npm, and an injected wallet such as MetaMask. From the repository root, run:

```bash
make local
```

This one command installs UI dependencies if needed, starts Anvil on port 8545, deploys the local contracts on a fresh chain, and starts the UI on port 5173. If the NaN UI is already running there, it reuses it. Press Ctrl-C to stop the services this command started. Anvil automatically saves to the ignored `.anvil/state.json` on clean exit and every 15 seconds while running. Restart with `make local` to restore balances, transactions, and the existing deployment; it will not redeploy over saved state. Keep `.anvil/state.json` together with `ui/public/local-deployment.json` if moving the playground to another machine.

Open [http://127.0.0.1:5173](http://127.0.0.1:5173). On first launch, the deployment script checks that the RPC is loopback Anvil chain 31337 and writes an ignored `ui/public/local-deployment.json` manifest for the UI. The Anvil test account key built into the local deployment script is public and **must never hold real funds**. You can override it with `LOCAL_PRIVATE_KEY` for another funded Anvil account. Import an Anvil account displayed in the `make local` terminal into a separate browser wallet profile, connect it to chain 31337, and keep real wallets/keys out of the playground. Never point the wallet or deployment script at a public chain.

If MetaMask reports `Requested resource not available` or repeated `eth_getBlockByNumber` RPC errors when you use the faucet, check its saved network entry for chain 31337. Its RPC URL must be `http://127.0.0.1:8545` on the same machine as Anvil, and the `make local` terminal must still be running. The UI can add a missing network, but MetaMask may retain an older RPC URL when chain 31337 was already configured; edit or remove that entry in MetaMask's network settings, then reconnect. The wallet also needs local ETH for gas, so import a funded Anvil test account rather than using an unfunded real-wallet address.

A quick walkthrough:

1. If your MetaMask address has no gas, use **Get local ETH** to top it up to 10 test ETH. Connect your wallet first or paste its address; the top-up uses Anvil's local RPC and does not need a transaction. Then use the faucet for 500 local wstETH, fund 100 wstETH into INF, and mint NaN using 180 wstETH. Token approvals are prompted when needed.
2. Set stETH/USD to $1,500. Inspect the underwater reserve, INF NAV and positive recovery issuance floor; use **Fund reserve** with 10 wstETH, then return to $3,000 and checkpoint recovery.
3. Request an INF withdrawal. Raise the mock stETH price to $4,000 if the target debt ratio otherwise prevents an INF payout. Use **Jump to maturity**, settle during the one-day window, then claim. Partial settlement returns unfilled INF.
4. Toggle the primary stale or unavailable. NaN redemption uses the local fallback quote with the real router's premium; funding and debt-bearing INF settlement still require a fresh primary.

The UI also exposes fallback price, exchange rate, time travel, a recovery checkpoint and authorizer-only delay/halving updates. Anvil state is retained across ordinary `make local` restarts, but an explicit chain reset or removal of `.anvil/state.json` starts a new chain and redeploys contracts. The UI's `/rpc` route proxies to `127.0.0.1:8545` and is intended only for local development. Do not publish or host this UI with the mock controls enabled.

The **Local tokens** section shows the deployed wstETH, NaN, and INF contract addresses with copy buttons. **Add to MetaMask** uses the wallet's ERC-20 token-import prompt with each token's actual on-chain symbol and decimals; the mock collateral appears as `lwstETH` in MetaMask. If you access the UI through a forwarded port, also forward Anvil port 8545 so MetaMask can query chain 31337. Token suggestions are local to that chain and must be repeated after a fresh Anvil deployment if its addresses change.

On a fresh local deployment, `npm run smoke --prefix ui` exercises the same contracts without a browser: faucet → fund → mint → price crash → insolvent fund → withdraw → fallback redemption. It uses the public Anvil test key and changes chain state, so run it before starting a manual UI session or redeploy afterward.

For an isolated 50-wallet stress run, start a separate Anvil on port 8546, deploy with `PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8546 --broadcast`, then run `node ui/scripts/stress.mjs`. The script requires a fresh deployment and refuses port 8545. It exercises a 50-account withdrawal cohort, price spike and crash, recapitalization, redemptions, both-oracle failure, missed-settlement refund, and restored funding/minting/redemption. The local mock feed and faucet are intentionally controllable, so this is a protocol-state stress test, not a live-market oracle security test.

## Deployment

Copy `.env.example` to `.env` and set `AUTHORIZER` to the intended timelock or governance contract, plus the collateral, [direct Chainlink stETH/USD feed](https://data.chain.link/ethereum/mainnet/crypto-usd/steth-usd), Uniswap v3 factory, wstETH/WETH pool, WETH/USDC pool, and their token addresses for the target network. The deployment script creates the TWAP adapter, router, and non-upgradeable reserve. `STETH_USD_FEED` must quote one stETH in USD. The fallback treats one USDC as one USD, so a USDC premium above $1 could make redemption too generous.

On Ethereum mainnet, candidate pools are [wstETH/WETH 0.01%](https://www.geckoterminal.com/eth/pools/0x109830a1aaad605bbf02a9dfa7b0b92ec2fb7daa) and [WETH/USDC 0.05%](https://www.geckoterminal.com/eth/pools/0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640). Recheck the factory, token order, observation history, liquidity, and manipulation cost at deployment. A direct wstETH/USDC pool should not be substituted without its own depth analysis.

`TWAP_WINDOW` must be between 30 minutes and one day. Both `MIN_*_HARMONIC_LIQUIDITY` values are required; they are Uniswap liquidity units, not USD amounts. Set them from target-pool observations and economic stress tests. The router constructor calls the TWAP once, so deployment fails if the fallback is invalid at that moment.

`FALLBACK_PREMIUM_BPS` increases the fallback redemption conversion price, reducing the wstETH withdrawn per NaN. It is not a guarantee against manipulated pool prices or a USDC depeg. Check both source quotes and staleness limits against target-network conditions before deployment.

Review every address and parameter independently, then simulate before broadcasting:

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

The sample defaults (30% minimum, 55% target, 65% maximum debt ratio, 10 bp mint/redemption fees, and a one-day recovery-price halving period) are test parameters, not an economic recommendation. The three-day INF withdrawal delay is separate from recovery-price decay. A deployment must also establish an adequate initial INF buffer with `fund` before opening NaN minting to users. Verify that `reserve.owner()` is the intended authorizer immediately after deployment. This change requires a new deployment; it cannot upgrade an existing immutable reserve.

## Integration notes

- Always pass a meaningful minimum output to quoted state-changing calls. A withdrawal request fixes no price; `claimDefund` can check a minimum against the already-fixed settlement payout.
- For INF exits, approve the active `reserve.inf()` token, call `requestDefund(infAmount)`, and record the returned `(series, epoch)`. After `withdrawalMaturity(series, epoch)`, anyone may call `settleDefundEpoch(series, epoch)` before `withdrawalExpiry(series, epoch)`. Then the requester calls `claimDefund(series, epoch, minCollateralOut, recipient)`. If settlement does not occur in the window, anyone may call `expireDefundEpoch(series, epoch)` so requesters can reclaim their INF. A request may be partially filled or receive no collateral; it is not a guaranteed payout at maturity.
- Cohorts provide a minimum wait equal to the delay set when that cohort opened, plus up to one batching epoch. One request per address per cohort is supported; use another cohort for a later request. Read `currentWithdrawalEpoch()` for the current epoch ID and closing time; do not calculate IDs by dividing timestamps. `infWithdrawalEpoch()` is the configured length, which may be pending until `withdrawalEpochScheduleStart()`. Repeated updates before that boundary replace the pending length without moving the boundary or changing the current cohort. Requests in the same cohort share the same maturity even if governance changes the delay mid-epoch.
- Use `redemptionCollateralPriceUsd()` to see the active redemption quote and whether fallback mode is in use. Ordinary reserve health and NAV views require the primary feed.
- Track `OracleUpdated`, `DebtRatiosUpdated`, `FeesUpdated`, `InfWithdrawalDelayUpdated`, `InfWithdrawalEpochUpdated`, `RecoveryHalvingPeriodUpdated`, and OpenZeppelin ownership events. Router components are individually immutable, so changing a feed, TWAP pool, staleness limit, or fallback premium means deploying a new router and calling `setOracle`. The new router must return positive normal and redemption prices when selected.
- `reserve.inf()` is permanent. `juniorSeries()` remains fixed at 1 only to preserve the withdrawal API's namespace; there are no token versions. Queued INF is diluted alongside all other outstanding INF.
- Use `previewFund(collateralIn)` for exact output, `fundingPriceUsd()` for the upward-rounded marginal issuance price, and `infPriceUsd()` for actual residual NAV. Never display the issuance floor as a guaranteed redemption value. `fund` is the only INF deposit entry point, including during insolvency, and emits `Funded` once per deposit. Integrators must remove the obsolete `recapitalize` call and `Recapitalized` event from their ABI.
- Track `RecoveryStarted`/`RecoveryEnded` and the public `recovery` snapshot. `recoveryFloorPriceUsd()` projects a fresh primary observation but does not start or reset the clock. Anyone can persist an observation with `checkpointRecovery()`. The episode snapshots its halving period and maximum-ratio exit threshold. A return to the healthy band alone does not end the episode: real NAV must also catch up to the floor, avoiding a cheaper second deposit at the recovery boundary. A rebound need not reach the lower withdrawal target to reset the clock.
- Observations do not prove uninterrupted distress. An unobserved rebound cannot reset the clock, and elapsed wall time during primary outages still counts after an episode starts. Fallback redemptions neither start nor clear pricing episodes. Production monitoring should checkpoint significant primary-observed state changes.
- Direct wstETH transfers are donations to the reserve and do not mint claims.
- Oracle freshness remains a liveness dependency for minting and debt-bearing junior settlement. Debt-free INF settlement and the refund of expired requests do not need an oracle. NaN redemption uses the independent fallback during primary failure, but halts if both sources are invalid.
- The INF queue follows the request/settlement/claim pattern of ERC-7540 but does not implement ERC-4626 or claim ERC-7540 compliance. The delay does not prevent a longer price rally followed by a crash; the current target debt ratio remains the settlement safety check. Governance updates to the target or oracle affect unsettled requests, but updates to the delay do not change an already-opened cohort's maturity.

## Scope

NaN deliberately has no upgrade proxy, emergency pause, secondary yield strategy, privacy layer, or user CDPs. The oracle fallback keeps NaN redemption available after a primary feed failure if both Uniswap pools remain valid and liquid. The authorizer can repair a failed oracle dependency by rotating the router, but cannot alter the immutable core rules. A malicious or compromised authorizer can nevertheless select a bad oracle or unsafe ratios; monitoring, a timelock, and independent review remain essential.
