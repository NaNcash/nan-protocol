# Primary oracle freshness policy

`script/Deploy.s.sol` requires an explicit, nonzero `MAX_STALENESS` in seconds.
There is no generic default, and `.env.example` deliberately leaves it blank.
Choose it for the exact feed and chain before simulation or broadcast. The script
cannot discover a Chainlink heartbeat through `AggregatorV3Interface` and does not
certify that an operator-supplied value matches the feed's configuration.

## Verified mainnet reference

The README's intended reference is the **direct stETH/USD market feed on Ethereum
mainnet (chain ID 1)**. This is a reference configuration, not a claim that a
production reserve has been deployed with these settings.

| Item | Verified value |
| --- | --- |
| Feed proxy (`STETH_USD_FEED`) | `0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8` |
| Underlying aggregator at verification | `0x26f196806f43E88FD27798C9e3fb8fdF4618240f` |
| Description / decimals | `STETH / USD` / 8 |
| Published heartbeat | 3,600 seconds (1 hour) |
| Published deviation threshold | 1% |
| Verification date (UTC) | 2026-10-18 |
| Reference `MAX_STALENESS` | 4,500 seconds (75 minutes) |
| Margin beyond heartbeat | 900 seconds (15 minutes) |

Sources: Chainlink's [stETH/USD feed page](https://data.chain.link/ethereum/mainnet/crypto-usd/steth-usd)
and [Ethereum mainnet reference data](https://reference-data-directory.vercel.app/feeds-mainnet.json)
(entry `path = steth-usd`). The reference data supplies the proxy, aggregator,
heartbeat, deviation threshold and decimals. Read-only mainnet calls to
`description()`, `aggregator()` and `latestRoundData()` confirmed the feed identity
and a positive, complete round. Chainlink documents the [heartbeat and deviation
update triggers](https://docs.chain.link/data-feeds/historical-data): updates may
arrive earlier on price deviation; the heartbeat is not a guaranteed onchain
publication deadline. Historical inter-round gaps alone do not establish it.

The 15-minute margin tolerates bounded transmission and block-inclusion delays
after a nominal hourly update. It is an explicit operational risk budget, not a
measured worst-case delay or a Chainlink availability guarantee. An age of exactly
4,500 seconds is accepted; 4,501 seconds is rejected. This permits a price to be up
to **75 minutes old**, including up to 15 minutes beyond the expected heartbeat.
It does not bound market-price error, guarantee a depeg is observed promptly, or
keep the protocol live through a longer outage. A larger threshold would extend
that stale-price exposure and requires a new risk decision. In particular, the
24-hour heartbeat of stETH/ETH must not be substituted for this direct USD feed.

To use this reference after rechecking it, explicitly set `STETH_USD_FEED` to the
proxy above and `MAX_STALENESS=4500`. For another feed or chain, record the chain
ID, proxy, underlying aggregator, quote currency, decimals, official heartbeat,
verification source/date, chosen margin, and maximum accepted age before setting
the environment. Recheck at each deployment or router rotation; published feed
configuration and underlying aggregators can change. Keep the deployment record
with the simulation output and deployed router address. Local and Sepolia
playgrounds use controllable synthetic feeds; their one-hour limits do not
represent a production-feed policy.

## Availability and monitoring

| Operation | Valid primary within configured age | Primary stale, invalid or unavailable |
| --- | --- | --- |
| NaN mint / redeem, INF fund | Available subject to normal limits | Reverts |
| Debt-bearing INF withdrawal settlement | Available subject to normal limits | Reverts |
| Reserve health, NAV and redemption-price views | Available | Reverts |
| INF withdrawal request | Available | Available |
| Claim already fixed collateral / unfilled INF | Available | Available |
| Expire a request after its settlement window | Available | Available |
| Debt-free INF settlement | Available subject to normal limits | Available subject to normal limits |

The diagnostic TWAP fallback cannot authorize reserve payouts. Restoring a valid
primary round restores priced operations; transactions that revert during an
outage do not change reserve balances or debt. Monitor `latestRoundData().updatedAt`
and alert as its age approaches the heartbeat, then the configured maximum.
Monitor feed configuration changes as well as actual update gaps. Rehearse both
normal update intervals plus the margin and an outage beyond the cutoff.

## Existing deployments

`WstEthUsdOracle.maxStaleness` is immutable. Changing this script, the sample
environment or source code does **not** reconfigure an existing router. Inventory
the deployed chain, reserve, router, feed and `maxStaleness()` first. Deploy a new
router with the reviewed settings, check that its primary and diagnostic quotes
are valid, then have the reserve's authorizer call `setOracle(newRouter)` under
its existing governance process. Monitor `OracleUpdated` and verify the selected
router and freshness limit afterward. Router rotation preserves the reserve and
tokens. Raising the age limit only changes the tolerated age; it does not repair
an unavailable feed or make old data accurate.

The accepted trust compromise is dependence on primary-feed publication and on
the authorizer to replace a broken router. Users can call the contracts through
another RPC or client, but cannot bypass a stale primary to redeem NaN. INF claims
and expiry refunds retain the oracle-free paths above. This configuration change
adds no new custody, admin powers, or collection of user data. Source and build
steps remain visible; the existing `UNLICENSED` notices do not grant permission
to operate a fork.

## Validation

`DeployConfig.t.sol` checks that blank/zero limits fail and explicit values survive
configuration loading. `WstEthUsdOracle.t.sol` checks the inclusive boundary and
one-second expiry across fuzzed limits, plus invalid answers, rounds and timestamps.
`OracleFreshness.t.sol` exercises normal heartbeat delays, stale outages, recovery,
oracle-free withdrawal paths and immutable-router rotation with the reference age.
The optional `WstEthUsdOracle.fork.t.sol` checks the real mainnet feed and wrapper:

```bash
forge test --match-contract 'DeployConfigTest|WstEthUsdOracleTest|OracleFreshnessTest'
NAN_MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
  forge test --match-contract WstEthUsdOracleForkTest -vv
```
