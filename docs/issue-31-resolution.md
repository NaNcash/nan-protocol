# Issue #31 resolution

Rechecked [issue #31](https://github.com/NaNcash/nan-protocol/issues/31) against latest main `c34f966`, rather than assuming the findings against `c34de01` still apply.

| Item | Assessment | Resolution and regressions |
| --- | --- | --- |
| 1. Router constructor fallback dependency | Still present; a diagnostic outage blocks router creation | Accept reverting/zero diagnostic quotes while retaining address, bytecode, configuration and successful-response ABI checks. Test failed diagnostics, recovery, healthy primaries, malformed responses and router replacement during an outage in `WstEthUsdOracle.t.sol` and `OracleFallback.t.sol`. |
| 2. Funding-cap helper mismatch | Already removed | [PR #30](https://github.com/NaNcash/nan-protocol/pull/30), commit `0cbf597`, removed `maxFundableUsd`, `_checkFundingCap`, the minimum ratio and `DebtRatioTooLow`. Current scripts, UI and tests use the revised API; the UI calls `previewFund` for specific collateral inputs. Existing `InfFunding.t.sol` regressions cover uncapped funding across/below the former minimum, debt-free funding, preview/execution agreement and retained mint/withdrawal limits. No cap is reintroduced. |
| 3. Withdrawal capacity rounding | Still present; USD subtraction can overstate the collateral budget | Share required-backing collateral arithmetic between reporting and settlement. Document capacity as a bound subject to subsequent INF/USD/output rounding. `WithdrawalCapacity.t.sol` covers adjacent target boundaries with non-integer conversions, executable fills, zero capacity, debt-free exits and fuzzed prices/surpluses with target backing and accounting checks. |
| 4. TWAP accumulator wraparound | Still present; widened tick subtraction and monotonic liquidity checks reject valid wraps | Subtract in source widths inside a scoped `unchecked` block. Keep length validation before indexing, negative tick rounding, invalid-observation rejection and both liquidity thresholds. `UniswapV3TwapOracle.t.sol` covers positive/negative tick wraps, liquidity wraps, arbitrary accumulator offsets, malformed arrays, ordinary observations and invalid/thin liquidity. |
| 5. Inter-cohort ordering | Existing behavior is first successful settlement; FIFO was never guaranteed | Retain this policy explicitly. `WithdrawalPriority.t.sol` covers both settlement orders during overlapping windows, delay-induced maturity inversion, unserviced earlier cohorts, zero capacity, empty/expired epochs, permissionless progress, accounting and oracle-free expiry/refunds. |

The new constructor tests, wrap tests and capacity fuzz regression fail against the corresponding previous implementations. Priority tests establish the retained policy; they do not claim an ordering vulnerability was repaired.

The [withdrawal design](../DESIGN.md#defund) defines capacity rounding and inter-cohort priority. The [oracle design](../DESIGN.md#oracle) defines unavailable diagnostics and the limits of constructor interface validation. Recovery issuance floors, share precision protection, senior target backing and primary-only reserve payouts are retained. Claim liveness for rounding dust remains handled by the existing #27 fix rather than counted as a new loss.

## Deployment and integration

These contracts are immutable. Existing router bytecode does not gain the constructor or TWAP changes. Deploy a new TWAP source and router with reviewed primary/fallback configuration, then have the reserve authorizer call `setOracle` while the replacement primary is healthy. A diagnostic fallback outage alone no longer prevents that deployment or rotation. The constructor and external oracle APIs are unchanged. Diagnostics must treat `FallbackUnavailable` as unavailable data, never as reserve payout permission. A failed constructor probe proves neither interface identity nor correctness: verify deployed fallback code and immutable configuration before selecting it.

The shared capacity calculation changes `NaNReserve` bytecode and requires a new reserve deployment to obtain that implementation. Router rotation alone cannot update an existing reserve's capacity helper. Existing reserve migration requires a separately reviewed integration/deployment plan; no onchain deployment or state migration is performed by this PR. `maxDefundableUsd()` keeps its ABI but now reports the collateral budget's USD value. Integrators should expect potentially lower capacity at rounding boundaries and must not promise an exact INF fill from this helper.

The priority policy introduces no storage or eligibility changes. Integrators should disclose overlapping-window competition and governance delay changes, monitor each cohort's fixed maturity/expiry and use permissionless expiry/refund if capacity never becomes available. No global head-of-line dependency is added.

## Validation

- `forge test -vv`: 228 passed, zero failed; the two RPC-dependent fork cases skip without an RPC URL. Fuzz tests use 1,000 runs; stateful invariants use 256 runs with depth 64.
- `NAN_MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path 'test/*.fork.t.sol' -vv`: both existing mainnet oracle integration tests passed, zero skipped.
- `forge fmt --check`, `forge build --sizes`, `forge lint` and `git diff --check` passed. Lint reports only existing timestamp and invariant-test cast warnings; production contracts remain within deployment size limits.
- `python3 model/simulate.py` and `python3 model/check_invariants.py` passed, including 100,000 randomized checks per model invariant.
