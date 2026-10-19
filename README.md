# NaN Protocol

NaN is a non-upgradeable, wstETH-backed stablecoin protocol with two claims on one reserve:

- **NaN** is the senior USD-denominated claim.
- **INF** is the junior residual claim. It absorbs collateral losses first and receives wstETH yield and protocol fees.

This is an **unaudited prototype**. Do not deploy it with real value before independent economic review, smart-contract audits, oracle review, and parameter validation.

## Protocol operations

| Operation | Input | Output | Availability |
| --- | --- | --- | --- |
| `fund` | wstETH | Permanent INF at the greater of NAV and the recovery issuance floor | Fresh primary oracle and minimum INF precision; no debt-ratio funding cap; incremental insolvent funding allowed |
| `mint` | wstETH | NaN less mint fee | Fresh primary oracle, at least `MIN_INF_SUPPLY` active INF, and post-mint debt ratio at or below the maximum |
| `requestDefund` | INF | A locked withdrawal request | One request per address and cohort; no oracle quote is fixed |
| `settleDefundEpoch` | Matured cohort | Accumulated wstETH payout; claims open on full fill, dust finalization, or expiry | After the cohort's snapshotted delay; fresh primary oracle and target debt-ratio limit when debt exists |
| `claimDefund` | Settled request | Fixed wstETH payout and unfilled INF | Oracle-free pull claim |
| `redeem` | NaN | wstETH less redemption fee | Fresh primary oracle; pro rata and fee-free when insolvent |
| `checkpointRecovery` | None | Persisted pricing-episode observation | Permissionless; fresh primary oracle required |

The reserve is non-upgradeable and has an OpenZeppelin two-step owner serving as its authorizer. The authorizer can replace the entire oracle router and update the ordered target and maximum debt ratios, mint/redemption fees, INF withdrawal delay, batching epoch length, and recovery-price halving period for future episodes. It cannot mint tokens, pause user actions, withdraw collateral, change the collateral token, or rewrite the senior/junior claim rules. Ownership cannot be renounced. Use a timelocked governance contract as the authorizer in production; these powers can materially affect users.

## Safety properties

- INF funding has no debt-ratio cap, including with outstanding debt. Normal NAV funding preserves existing per-token NAV apart from rounding; investors choose the resulting leverage and fee participation. INF withdrawal settlement preserves `targetDebtRatioBps`, and minting preserves `maxDebtRatioBps`. The ratios must satisfy `0 < target < max < 10,000` basis points.
- INF withdrawals settle by cohort after the configured delay, initially three days, plus the remaining batching time. Governance can set the delay between one and 30 days and the batching epoch between one hour and seven days (initially one day). Epoch-length updates apply at the current epoch's closing boundary, preserving its ID and end time. Each cohort snapshots its maturity when its first request arrives, so later governance changes cannot shorten or extend pending requests. Each cohort has a one-day settlement window. Zero-capacity settlement reverts without consuming eligibility; partial fills accumulate and can be retried in the same window. Claims open on full fill, after a positive payout leaves only an unburnable or zero-collateral rounding remainder, or on permissionless expiry. Finalization preserves accumulated collateral and refunds unfilled INF; a capacity-limited remainder with a nonzero collateral quote remains retryable. Settlement uses the then-current price, not the request-time price. Limited safe exit capacity is allocated pro rata within a cohort.
- Settled but unclaimed wstETH is excluded from reserve backing. Pending INF remains in total supply until its filled portion is burned at settlement.
- Insolvent NaN redemption is pro rata, so early redeemers cannot take $1 while leaving later holders with the loss.
- INF has one immutable address. Recapitalization dilutes existing holders rather than cancelling their claims, and need not restore solvency in one transaction. Recovery pricing starts on an observed breach of the maximum debt ratio, with a positive USD/INF issuance floor that halves every day by default (linear interpolation between halvings). It never changes actual senior debt, INF NAV, or withdrawal entitlements. Severe dilution and failure to attract funding remain possible.
- The initial oracle router uses a fresh direct stETH/USD feed multiplied by `stEthPerToken()` for normal operations. NaN redemption also requires the primary and halts during primary outages. The two-pool Uniswap v3 TWAP for wstETH/WETH and WETH/USDC and its premium remain available through the router's legacy diagnostic API, but cannot authorize reserve payouts. A lagging TWAP plus a fixed premium does not bound the current market price; this policy sacrifices outage availability to prevent that source of junior-equity loss. The authorizer can deploy and select a new router if either source needs replacement.
- Both fees are authorizer-settable but capped at 1,000 basis points each. Solvent redemption fees are further capped by the burned fraction of pre-redemption equity: `min(floor(nanIn * redeemFeeBps / 10_000), floor(nanIn * equity / debt))`. This removes the fee jump at exact solvency. Retained fees increase INF equity, so splitting a redemption can cost more as later burns use the new equity and remaining debt. An insolvent redemption still has no explicit fee. See [DESIGN.md](DESIGN.md#redeem) for rounding and split-redemption examples.
- The primary is checked for a positive answer, valid timestamp, staleness, and completed round. The TWAP requires a full observation window, canonical Uniswap pools, and minimum current and time-weighted liquidity in both pools; unavailable or thin pools invalidate the diagnostic fallback quote.
- Fee-on-transfer collateral is rejected, and only 18-decimal collateral is accepted.
- INF funding must mint at least `MIN_INF_SUPPLY` (one billion base units, or 0.000000001 INF), bounding share-quote rounding loss below one billionth even with one existing share. Withdrawals may leave less supply so fragmented holders can exit independently across cohorts, including a complete debt-free exit to zero. Below the operating minimum, existing NaN remains redeemable but new NaN issuance requires funding to restore the minimum. Deposits with coarser output revert even with a zero minimum, and withdrawals never burn INF for zero aggregate collateral. Debt-bearing exits still preserve target-ratio backing; fragments worth less than one collateral base unit remain subject to rounding.
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
3. Request an INF withdrawal. Raise the mock stETH price to $4,000 if the target debt ratio otherwise prevents an INF payout. Use **Jump to maturity**, settle during the one-day window, then claim. If settlement is partial, retry within the window or advance to expiry and finalize the cohort before claiming accumulated collateral and unfilled INF.
4. Toggle the primary stale or unavailable. NaN redemption, funding, minting, and debt-bearing INF settlement halt. Restore the primary to resume. The fallback controls affect only the router's diagnostic quote.

The UI also exposes fallback price, exchange rate, time travel, a recovery checkpoint and authorizer-only delay/halving updates. Anvil state is retained across ordinary `make local` restarts, but an explicit chain reset or removal of `.anvil/state.json` starts a new chain and redeploys contracts. The UI's `/rpc` route proxies to `127.0.0.1:8545` and is intended only for local development. Do not publish or host this UI with the mock controls enabled.

The **Local tokens** section shows the deployed wstETH, NaN, and INF contract addresses with copy buttons. **Add to MetaMask** uses the wallet's ERC-20 token-import prompt with each token's actual on-chain symbol and decimals; the mock collateral appears as `lwstETH` in MetaMask. If you access the UI through a forwarded port, also forward Anvil port 8545 so MetaMask can query chain 31337. Token suggestions are local to that chain and must be repeated after a fresh Anvil deployment if its addresses change.

On a fresh local deployment, `npm run smoke --prefix ui` exercises the same contracts without a browser: faucet → fund → mint → price crash → insolvent fund → withdraw → outage halt → restored redemption. It uses the public Anvil test key and changes chain state, so run it before starting a manual UI session or redeploy afterward.

For an isolated 50-wallet stress run, start a separate Anvil on port 8546, deploy with `PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8546 --broadcast`, then run `node ui/scripts/stress.mjs`. The script requires a fresh deployment and refuses port 8545. It exercises a 50-account withdrawal cohort, price spike and crash, recapitalization, redemptions, primary-outage rejection with a healthy fallback, both-oracle failure, missed-settlement refund, and restored funding/minting/redemption. The local mock feed and faucet are intentionally controllable, so this is a protocol-state stress test, not a live-market oracle security test.

## Sepolia playground

The Sepolia mode uses the existing reserve and oracle router with **Playground Ether (`pgETH`)**, a freely mintable 18-decimal ERC-20 collateral token. It is not native ETH, wrapped ETH, or redeemable for ETH, and has no monetary value. Anyone can mint up to 1,000 pgETH per faucet transaction and repeat as needed. Native Sepolia ETH is needed only for deployment and transaction gas. The deployer receives 300,000 initial INF for seeding the reserve with 100 free pgETH; visitors can immediately mint NaN, subject to the reserve's debt-ratio limit.

The new playground contracts and deployment script refuse chains other than Sepolia (`11155111`). They use synthetic USD prices, initially $3,000 with a 1:1 value multiplier. A healthy feed stays fresh without a keeper; it does not follow the market. Only each mock's owner can change the price, rate, or outage settings. `SEPOLIA_AUTHORIZER` sets the initial controller of all three mocks and the reserve, defaulting to the deployment wallet. Scenario changes affect every user of this deployment. Local Anvil mocks and the production deployment script remain separate.

Prepare dependencies and a private config file from the repository root:

```bash
npm ci --prefix ui
cp .env.sepolia.example .env.sepolia
chmod 600 .env.sepolia
```

Import a **dedicated Sepolia wallet** into Foundry's encrypted keystore using `cast wallet import sepolia-deployer --interactive`. Put the account name in `SEPOLIA_ACCOUNT` in the root `.env.sepolia`; the default is `sepolia-deployer`. Keep private keys and passwords out of this config and chat. Set `SEPOLIA_RPC_URL` to your Sepolia HTTP(S) endpoint; the template includes a public endpoint, which may rate-limit requests. The config, broadcast logs, and local Anvil manifest are ignored by Git. The public Sepolia manifest contains only addresses and chain metadata and is committed with the frontend for hosting. The deployment wrapper rejects standard Anvil accounts and checks the RPC chain before invoking Forge. Optionally set `SEPOLIA_AUTHORIZER` to the wallet you want to use for scenario controls, and `ETHERSCAN_API_KEY` for source verification during broadcast.

When you run `make sepolia-deploy` in a terminal, Foundry prompts for the keystore password once; no password file is needed. The script resolves the unlocked wallet directly from Foundry. To deploy from an automated session, create a local password file with permissions `600`, then set `SEPOLIA_PASSWORD_FILE` to its absolute path. The file is passed directly to Foundry; its contents are never read by the deployment wrapper or written to the manifest. Remove the temporary password file after deployment. A dry run can use `SEPOLIA_DEPLOYER=<public wallet address>` without unlocking the keystore; broadcasting verifies that the selected keystore actually matches that address.

Run a simulation first to validate the contract logic. On Sepolia after Glamsterdam, older Foundry versions still print gas totals from the earlier gas schedule; those totals understate deployment cost. `sepolia-deploy` uses Sepolia RPC gas estimation with 30% headroom for each transaction immediately before sending it. Fund the deployment wallet for the current network costs, then deploy:

```bash
make sepolia-dry-run
make sepolia-deploy
make sepolia-ui
```

Only `sepolia-deploy` sends transactions. It runs the deployment script, forces sequential RPC gas estimation through Forge’s `--skip-simulation` mode to avoid outdated local gas estimates, seeds backing with an exact collateral approval, then validates receipts, deployed bytecode, reserve wiring, and controller ownership before writing `ui/public/sepolia-deployment.json`. If the manifest already exists, archive it before intentionally deploying another stack. If broadcast or verification fails after transactions have been sent, inspect `broadcast/DeploySepolia.s.sol/11155111/run-latest.json` and complete/resume that deployment before retrying. `make sepolia-manifest` recovers the manifest after a completed deployment without sending transactions; it verifies recorded receipts against the configured chain. Do not use `sepolia-manifest` to publish a partially completed deployment.

Open [http://127.0.0.1:5173](http://127.0.0.1:5173), connect a Sepolia test wallet, get free pgETH, then fund INF or mint NaN. Deposit and withdrawal buttons show an explicit token approval step; after approval confirms, click the action again to execute it. This mode switches the wallet to Sepolia, labels pgETH separately from native gas ETH, restricts scenario buttons to the appropriate mock owner, and removes Anvil balance top-ups and time travel. Withdrawals use real time: the default wait is three days after the daily cohort closes. Matured cohorts still need a user to settle or expire them, then each requester claims their payout. Recovery checkpoints remain permissionless.

`make sepolia-ui` uses the configured RPC through Vite's local `/rpc` proxy; RPC credentials stay server-side and deployment keys are removed from the UI process environment. For a static frontend, build **after** the real deployment manifest is generated:

```bash
VITE_PLAYGROUND_NETWORK=sepolia npm run build --prefix ui
```

The static build uses the public PublicNode Ethereum Sepolia endpoint. Override it with `VITE_SEPOLIA_RPC_URL` when building if needed; this value is exposed to every browser, so it must not contain private credentials. Host `ui/dist` as static files, including `sepolia-deployment.json`. The dev `/rpc` proxy is unnecessary for this build. Hosting the UI is a separate step from deploying contracts.

### Automatic Netlify deployment

The root `netlify.toml` builds the static Sepolia frontend with Node 24. It sets the base directory to `ui`, runs `npm run build:sepolia`, and publishes `ui/dist`. Netlify installs dependencies from `ui/package-lock.json`. The build validates the committed Sepolia deployment manifest, forces Sepolia mode, and excludes the local Anvil manifest. It uses existing deployed contracts and needs no Foundry installation, private key, keystore, or deployment password.

To connect automatic deployments:

1. Commit and push the frontend changes, `netlify.toml`, and `ui/public/sepolia-deployment.json` to your GitHub repository. The Sepolia manifest contains public contract addresses and must be included so a fresh checkout can build.
2. In Netlify, choose **Add new project → Import an existing project**, connect GitHub, and select `NaNcash/nan-protocol`.
3. Select your production branch. Netlify should read the checked-in settings: base directory `ui`, build command `npm run build:sepolia`, publish directory `dist` (relative to `ui`).
4. Deploy. Netlify supplies an HTTPS `*.netlify.app` URL. Subsequent pushes to the selected branch automatically rebuild and publish the frontend; pull requests can receive preview deployments.
5. Open the published URL and confirm the reserve loads and your wallet switches to Ethereum Sepolia. Native Sepolia ETH remains necessary for wallet transaction gas.

No Netlify environment variables are required for the default setup. You can optionally set `VITE_SEPOLIA_RPC_URL` to a browser-accessible Sepolia RPC and trigger a rebuild. Vite embeds that URL in public JavaScript, so use a public endpoint or a provider key intended for browser use with the appropriate domain restrictions. Do not add deployment keys, keystore passwords, or server-only RPC credentials to Netlify. The hosted build reads Sepolia directly and does not use Vite's local `/rpc` proxy.

To reproduce the Netlify build locally:

```bash
npm ci --prefix ui
npm run build:sepolia --prefix ui
```

When deliberately deploying a replacement Sepolia stack, commit the updated `ui/public/sepolia-deployment.json` and push it to update the hosted UI. Netlify's frontend deployments do not send blockchain transactions.

If source verification was not configured, verify the deployed contracts before sharing the public playground. Constructor arguments and addresses are recorded in the Forge broadcast output; use `forge verify-contract --chain 11155111` with the matching contract, encoded arguments, and verifier credentials. Include the reserve-created NaN and INF tokens (both constructors take the reserve address), as well as the collateral, synthetic primary, diagnostic fallback, router, and reserve.

Trust review for this playground: the chosen default is a self-hostable UI, replaceable RPC, injected test wallet, and permissionless faucet/user actions. RPC providers can block access or see requests and IP metadata; users can change the endpoint, rebuild the UI, or call contracts directly using the ABIs in `out/`. Addresses, balances, and transactions are public. The controller can alter synthetic prices and halt priced actions by simulating a feed outage; restoring the feed is necessary for redemption. Expired INF requests can still be finalized and claimed without an oracle. The core reserve is immutable and has no admin collateral-withdrawal function, but governance can change its oracle and parameters. Single-wallet scenario control and unlimited test collateral are accepted testnet compromises. Source and build instructions are available, but the project's existing `UNLICENSED` Solidity notices do not grant an open-source license. This setup is a shared simulation and must never be used for real-value collateral.

## Deployment

Copy `.env.example` to `.env` and set `AUTHORIZER` to the intended timelock or governance contract, plus the collateral, [direct Chainlink stETH/USD feed](https://data.chain.link/ethereum/mainnet/crypto-usd/steth-usd), Uniswap v3 factory, wstETH/WETH pool, WETH/USDC pool, and their token addresses for the target network. The deployment script retains the TWAP adapter and router configuration for compatibility, and creates the non-upgradeable reserve; its payouts use only the router's primary price. `STETH_USD_FEED` must quote one stETH in USD. The diagnostic fallback treats one USDC as one USD, so a USDC premium above $1 can distort that quote; the reserve does not use it for redemption.

On Ethereum mainnet, candidate pools are [wstETH/WETH 0.01%](https://www.geckoterminal.com/eth/pools/0x109830a1aaad605bbf02a9dfa7b0b92ec2fb7daa) and [WETH/USDC 0.05%](https://www.geckoterminal.com/eth/pools/0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640). Recheck the factory, token order, observation history, liquidity, and manipulation cost at deployment. A direct wstETH/USDC pool should not be substituted without its own depth analysis.

`TWAP_WINDOW` must be between 30 minutes and one day. Both `MIN_*_HARMONIC_LIQUIDITY` values are required; they are Uniswap liquidity units, not USD amounts. Set them from target-pool observations and economic stress tests. The router constructor calls the TWAP once, so deployment fails if the fallback is invalid at that moment.

`FALLBACK_PREMIUM_BPS` increases the legacy diagnostic quote. It is not a guarantee against manipulated pool prices or a USDC depeg and cannot authorize a reserve payout. Check both source quotes and staleness limits against target-network conditions before deployment.

`MAX_STALENESS` is required, must be nonzero, and has no default. Follow the [primary oracle freshness policy](docs/oracle-freshness.md) to verify the exact feed's heartbeat and choose a bounded publication margin. The documented Ethereum mainnet stETH/USD reference has a verified one-hour heartbeat and a 75-minute reference age limit; the sample leaves this value blank so another chain or feed cannot silently inherit it. Existing routers have immutable limits and require a new router plus an authorized `setOracle` call to change them.

Review every address and parameter independently, then simulate before broadcasting:

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

The sample defaults (55% target and 65% maximum debt ratios, 10 bp mint/redemption fees, and a one-day recovery-price halving period) are test parameters, not an economic recommendation. The three-day INF withdrawal delay is separate from recovery-price decay. A deployment must also establish an adequate initial INF buffer with `fund` before opening NaN minting to users. Verify that `reserve.owner()` is the intended authorizer immediately after deployment.

This change requires a new deployment; it cannot upgrade an existing immutable reserve. The constructor and `setDebtRatios(targetBps, maxBps)` accept only target and maximum ratios, and `DebtRatiosUpdated` emits those two values. The minimum-ratio parameter, `maxFundableUsd()`, and `DebtRatioTooLow` have been removed; integrations should quote specific collateral amounts with `previewFund` rather than derive funding capacity.

The checked-in Sepolia manifest refers to the earlier immutable deployment; redeploy and regenerate the manifest to use the revised funding rules. Existing reserves retain their old minimum, which cannot be set to zero.

## Integration notes

- Always pass a meaningful minimum output to quoted state-changing calls. A withdrawal request fixes no price; `claimDefund` can check a minimum against the already-fixed settlement payout.
- `MIN_INF_SUPPLY` is an operating and deposit-output threshold, not a withdrawal floor. Final INF holders can settle independently without combining tokens across addresses or epochs, subject to collateral precision and senior backing. Every successful `fund` restores the operating minimum; `mint` returns `NoJuniorCapital` below it. This policy requires a new immutable reserve deployment; earlier deployments retain their withdrawal floor.
- Quote NaN redemptions against the intended deployed reserve, including the equity cap and collateral/USD rounding. The playground simulates `redeem` with the connected account to derive its minimum output. The revised fee rule requires a new deployment because reserves are immutable; existing deployments, including the checked-in Sepolia manifest, retain their original fee rule.
- For INF exits, approve the active `reserve.inf()` token, call `requestDefund(infAmount)`, and record the returned `(series, epoch)`. After `withdrawalMaturity(series, epoch)`, anyone may call `settleDefundEpoch(series, epoch)` before `withdrawalExpiry(series, epoch)`. Partial fills emit `WithdrawalProgress` and leave the cohort eligible for more settlement in the same window; each fill uses the current NAV and earmarks collateral immediately. Once all INF is filled, `WithdrawalSettled` opens claims. At expiry, anyone may call `expireDefundEpoch(series, epoch)` to open claims for accumulated collateral and any unfilled INF, even if the oracle is unavailable. The requester then calls `claimDefund(series, epoch, minCollateralOut, recipient)`. A request may be partially filled or receive no collateral; it is not a guaranteed payout at maturity.
- Cohorts provide a minimum wait equal to the delay set when that cohort opened, plus up to one batching epoch. One request per address per cohort is supported; use another cohort for a later request. Read `currentWithdrawalEpoch()` for the current epoch ID and closing time; do not calculate IDs by dividing timestamps. `infWithdrawalEpoch()` is the configured length, which may be pending until `withdrawalEpochScheduleStart()`. Repeated updates before that boundary replace the pending length without moving the boundary or changing the current cohort. Requests in the same cohort share the same maturity even if governance changes the delay mid-epoch.
- Use `redemptionCollateralPriceUsd()` to see the primary redemption quote. Its legacy boolean is always false; the call reverts during primary outages. The router's `redemptionPrice()` may still return a fallback diagnostic quote, which the reserve does not use. Reserve health and NAV views also require the primary feed.
- Track `OracleUpdated`, `DebtRatiosUpdated`, `FeesUpdated`, `InfWithdrawalDelayUpdated`, `InfWithdrawalEpochUpdated`, `RecoveryHalvingPeriodUpdated`, and OpenZeppelin ownership events. Router components are individually immutable, so changing a feed, TWAP pool, staleness limit, or fallback premium means deploying a new router and calling `setOracle`. The new router must return positive normal and redemption prices when selected.
- `reserve.inf()` is permanent. `juniorSeries()` remains fixed at 1 only to preserve the withdrawal API's namespace; there are no token versions. Queued INF is diluted alongside all other outstanding INF.
- Use `previewFund(collateralIn)` for exact output, `fundingPriceUsd()` for the upward-rounded marginal issuance price, and `infPriceUsd()` for actual residual NAV. Never display the issuance floor as a guaranteed redemption value. `fund` is the only INF deposit entry point, including during insolvency, and emits `Funded` once per deposit. Integrators must remove the obsolete `recapitalize` call and `Recapitalized` event from their ABI.
- Track `RecoveryStarted`/`RecoveryEnded` and the public `recovery` snapshot. `recoveryFloorPriceUsd()` projects a fresh primary observation but does not start or reset the clock. Anyone can persist an observation with `checkpointRecovery()`. The episode snapshots its halving period and maximum-ratio exit threshold. A return to the healthy band alone does not end the episode: real NAV must also catch up to the floor, avoiding a cheaper second deposit at the recovery boundary. A rebound need not reach the lower withdrawal target to reset the clock.
- Observations do not prove uninterrupted distress. An unobserved rebound cannot reset the clock, and elapsed wall time during primary outages still counts after an episode starts. Primary outages halt redemption and cannot start or clear pricing episodes. Production monitoring should checkpoint significant primary-observed state changes.
- Direct wstETH transfers are donations to the reserve and do not mint claims.
- Oracle freshness remains a liveness dependency for funding, minting, NaN redemption, and debt-bearing junior settlement. Debt-free INF settlement and the refund of expired requests do not need an oracle. NaN redemption halts during primary failure even if the independent diagnostic fallback is valid.
- The INF queue follows the request/settlement/claim pattern of ERC-7540 but does not implement ERC-4626 or claim ERC-7540 compliance. The delay does not prevent a longer price rally followed by a crash; the current target debt ratio remains the settlement safety check. Governance updates to the target or oracle affect unsettled requests, but updates to the delay do not change an already-opened cohort's maturity.

## Scope

NaN deliberately has no upgrade proxy, emergency pause, secondary yield strategy, privacy layer, or user CDPs. A primary feed failure halts NaN redemption; the fallback remains diagnostic only. The authorizer can repair a failed oracle dependency by rotating the router, but cannot alter the immutable core rules. A malicious or compromised authorizer can nevertheless select a bad oracle or unsafe ratios; monitoring, a timelock, and independent review remain essential.
