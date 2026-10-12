# Entry Point Map

> NaN Protocol | 28 production entry points | 16 permissionless | 5 role-gated | 7 admin-only

Scope: non-view/non-pure callable functions on `NaNReserve`, `NaNToken`, and `INFToken`, including inherited OpenZeppelin functions. Both production oracle contracts expose only view functions after construction. Source scans include signatures with visibility on a later line; a fresh `forge inspect` verified the reserve's sixteen state-changing ABI functions. Local simulators are excluded.

## Protocol Flow Paths

### Deployment and ownership

`Deploy TWAP adapter` → `Deploy WstEthUsdOracle` → `Deploy NaNReserve` → automatic `new NaNToken` + `new INFToken`.
`Current owner.transferOwnership(newOwner)` → `Pending owner.acceptOwnership()` ◄── no time delay.

### Funding and senior issuance

`[deployment]` → `wstETH.approve(reserve)` → `fund()` ◄── primary valid; minimum ratio when debt exists.
`[funding]` → `wstETH.approve(reserve)` → `mint()` ◄── INF supply positive; post-trade maximum ratio.
`[minting or NaN transfer]` → `redeem()` ◄── caller owns NaN; primary or fallback valid.

### Junior withdrawals

`[funding or INF transfer]` → `INFToken.approve/permit(reserve)` → `requestDefund()`.
`[request]` → `[cohort close + snapshotted delay]` → `settleDefundEpoch()` ◄── within one-day window; capacity priced at settlement.
`[settlement]` → `claimDefund()` ◄── own positive request; returns fixed collateral plus unfilled INF.
`[request]` → `[maturity + one day]` → `expireDefundEpoch()` ◄── epoch not settled.
`[expiry]` → `claimDefund()` ◄── returns unfilled INF; no price call.
Debt-free settlement follows the same timing and uses in-kind collateral without an oracle.

### Recovery observation

`[INF supply exists]` → `[primary-priced distress or depleted reserve]` → `checkpointRecovery()`.
`[recorded episode + elapsed time]` → `fund()` ◄── current floor and NAV determine issuance.
`[recorded episode + ratio and NAV recovery]` → `checkpointRecovery()` ◄── can clear the episode.
Funding/minting and primary redemptions observe recovery too; fallback redemption does not.

## Permissionless

Functions may impose balance, approval, request-ownership, timestamp, and numeric guards without becoming protocol role-gated. No user operation has a pause modifier.

### `NaNReserve.fund()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:413` |
| Caller | Collateral provider |
| Parameters | `collateralIn`, `minInfOut`, `recipient` (user-controlled) |
| Call chain | `collateralPriceUsd → WstEthUsdOracle.price`; `_checkFundingCap → _syncRecovery → _fundingQuote → _pullExact → wstETH.transferFrom`; `INFToken.mint` |
| State modified | Recovery episode as needed; INF balances/total supply; collateral balances |
| Value flow | Collateral caller → reserve; newly minted INF → recipient |
| Reentrancy guard | Yes |

### `NaNReserve.mint()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:533` |
| Caller | Senior claim minter |
| Parameters | `collateralIn`, `minNanOut`, `recipient` (user-controlled) |
| Call chain | `collateralPriceUsd → WstEthUsdOracle.price`; `_syncRecovery → _withinMaxDebtRatio → _pullExact → wstETH.transferFrom`; `NaNToken.mint` |
| State modified | Recovery episode as needed; NaN balances/total supply; collateral balances |
| Value flow | Collateral caller → reserve; newly minted NaN → recipient; fee retained in reserve |
| Reentrancy guard | Yes |

### `NaNReserve.requestDefund()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:440` |
| Caller | INF holder |
| Parameters | `infIn` (user-controlled); returned series/epoch (protocol-derived) |
| Call chain | `currentWithdrawalEpoch → INFToken.transferFrom(caller, reserve)` |
| State modified | Cohort token/maturity on first request; caller request start/amount; cohort requested amount; INF balances/allowance |
| Value flow | INF caller → reserve escrow; no collateral movement |
| Reentrancy guard | Yes |

### `NaNReserve.redeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:565` |
| Caller | NaN holder; burns caller's balance without an allowance |
| Parameters | `nanIn`, `minCollateralOut`, `recipient` (user-controlled) |
| Call chain | `redemptionCollateralPriceUsd → WstEthUsdOracle.redemptionPrice`; `NaNToken.burn(caller)`; `wstETH.transfer(recipient)` |
| State modified | NaN balances/total supply; collateral balances; recovery only on primary-priced path |
| Value flow | Caller NaN burned; reserve collateral → recipient |
| Reentrancy guard | Yes |

### `NaNReserve.claimDefund()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:499` |
| Caller | Holder with own unclaimed request in a settled/expired cohort |
| Parameters | `series`, `epoch`, `minCollateralOut`, `recipient` (user-controlled) |
| Call chain | Prefix payout calculation → delete own request → `INFToken.transfer(caller)` and/or `wstETH.transfer(recipient)` |
| State modified | Caller request deleted; `claimableWithdrawalCollateral` reduced; INF/collateral balances |
| Value flow | Reserve collateral → chosen recipient; unfilled INF → caller |
| Reentrancy guard | Yes; no oracle call |

### `NaNReserve.settleDefundEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:463` |
| Caller | Settlement caller; no keeper role required |
| Parameters | `series`, `epoch` (user-controlled) |
| Call chain | `_withdrawalQuote`; if debt exists `collateralPriceUsd → WstEthUsdOracle.price → _syncRecovery`; `INFToken.burn(reserve)` when filled |
| State modified | Epoch `settled`, `filledInf`, `collateralOut`; claimable collateral increased; INF reserve balance/supply reduced; possible recovery observation |
| Value flow | Filled escrowed INF burned; collateral becomes earmarked without a physical transfer |
| Reentrancy guard | Yes |

### `NaNReserve.expireDefundEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | External; `src/NaNReserve.sol:488` |
| Caller | Expiry caller after settlement window |
| Parameters | `series`, `epoch` (user-controlled) |
| Call chain | Stored epoch/timestamp checks → set `settled = true`; no external calls |
| State modified | Epoch `settled`; payout/fill remain zero for an expired epoch |
| Value flow | None; refunds occur through subsequent holder claims |
| Reentrancy guard | No; no external calls |

### `NaNReserve.checkpointRecovery()`

| Aspect | Detail |
|--------|--------|
| Visibility | External, `nonReentrant`; `src/NaNReserve.sol:403` |
| Caller | Recovery observation caller |
| Parameters | None; price/reserve/debt/INF supply (protocol-derived) |
| Call chain | `reserveUsd → wstETH.balanceOf + WstEthUsdOracle.price`; `NaNToken.totalSupply + INFToken.totalSupply → _syncRecovery` |
| State modified | `recovery` created, retained, or deleted |
| Value flow | None |
| Reentrancy guard | Yes |

### `NaNToken.transfer()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:99` |
| Caller | NaN holder |
| Parameters | `to`, `value` (user-controlled) |
| Call chain | `ERC20._transfer → _update` |
| State modified | Sender/recipient NaN balances; total supply unchanged |
| Value flow | NaN caller → recipient |
| Reentrancy guard | No; no callbacks or external calls |

### `NaNToken.transferFrom()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:142` |
| Caller | Approved spender |
| Parameters | `from`, `to`, `value` (user-controlled, allowance-constrained) |
| Call chain | `ERC20._spendAllowance → _transfer → _update` |
| State modified | Owner/recipient balances; finite allowance reduced; infinite allowance retained |
| Value flow | NaN owner → recipient |
| Reentrancy guard | No; no callbacks or external calls |

### `NaNToken.approve()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:120` |
| Caller | Allowance owner |
| Parameters | `spender`, `value` (user-controlled) |
| Call chain | `ERC20._approve` |
| State modified | Caller/spender allowance |
| Value flow | None |
| Reentrancy guard | No; no external calls |

### `NaNToken.permit()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20Permit; `ERC20Permit.sol:42` |
| Caller | Signature submitter |
| Parameters | `owner`, `spender`, `value`, `deadline` (user-signed); `v`, `r`, `s` (user-signed signature) |
| Call chain | `Nonces._useNonce → EIP712._hashTypedDataV4 → ECDSA.recover → ERC20._approve` |
| State modified | Signed owner's nonce and allowance; invalid execution rolls back |
| Value flow | None |
| Reentrancy guard | No; no external calls |

### `INFToken.transfer()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:99` |
| Caller | INF holder |
| Parameters | `to`, `value` (user-controlled) |
| Call chain | `ERC20._transfer → _update` |
| State modified | Sender/recipient INF balances; total supply unchanged |
| Value flow | INF caller → recipient |
| Reentrancy guard | No; no callbacks or external calls |

### `INFToken.transferFrom()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:142` |
| Caller | Approved spender |
| Parameters | `from`, `to`, `value` (user-controlled, allowance-constrained) |
| Call chain | `ERC20._spendAllowance → _transfer → _update` |
| State modified | Owner/recipient balances and finite allowance |
| Value flow | INF owner → recipient |
| Reentrancy guard | No; no callbacks or external calls |

### `INFToken.approve()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20; `ERC20.sol:120` |
| Caller | Allowance owner |
| Parameters | `spender`, `value` (user-controlled) |
| Call chain | `ERC20._approve` |
| State modified | Caller/spender allowance |
| Value flow | None |
| Reentrancy guard | No; no external calls |

### `INFToken.permit()`

| Aspect | Detail |
|--------|--------|
| Visibility | Public, inherited ERC20Permit; `ERC20Permit.sol:42` |
| Caller | Signature submitter |
| Parameters | `owner`, `spender`, `value`, `deadline`, `v`, `r`, `s` (user-signed) |
| Call chain | `Nonces._useNonce → EIP712._hashTypedDataV4 → ECDSA.recover → ERC20._approve` |
| State modified | Signed owner's nonce and allowance |
| Value flow | None |
| Reentrancy guard | No; no external calls |

## Role-Gated

All parameters below are caller-selected, with authority supplied by the stated role. None of these functions transfers reserve collateral or calls an external protocol.

| Contract / function | Effective gate and caller | Parameters / trust | State and value flow | Guard / source |
|---------------------|---------------------------|--------------------|----------------------|----------------|
| `NaNToken.mint` | `msg.sender == reserve`; reserve | `to`, `amount` (protocol-derived) | `_mint`: supply +amount, recipient balance +amount; creates NaN | No reentrancy modifier; `src/NaNToken.sol:20–22` |
| `NaNToken.burn` | `msg.sender == reserve`; reserve | `from`, `amount` (protocol-derived) | `_burn`: supply −amount, source balance −amount; burns NaN | No reentrancy modifier; `src/NaNToken.sol:25–27` |
| `INFToken.mint` | `msg.sender == reserve`; reserve | `to`, `amount` (protocol-derived) | `_mint`: supply +amount, recipient balance +amount; creates INF | No reentrancy modifier; `src/INFToken.sol:20–22` |
| `INFToken.burn` | `msg.sender == reserve`; reserve | `from`, `amount` (protocol-derived) | `_burn`: supply −amount, source balance −amount; burns INF | No reentrancy modifier; `src/INFToken.sol:25–27` |
| `NaNReserve.acceptOwnership` | `msg.sender == pendingOwner()`; nominated successor | None | `_transferOwnership`: owner replaced; pending owner deleted; no token flow | No reentrancy modifier; inherited `Ownable2Step.sol:60–65` |

## Admin-Only

All are current-owner gated, without an embedded timelock, pause condition, or reentrancy modifier. Setter parameters are user-controlled by the privileged caller. No direct token flow occurs; `setOracle` calls the proposed router's price views.

| Contract | Function / source | Parameters | Call chain and state modified |
|----------|-------------------|------------|-------------------------------|
| NaNReserve | `setOracle`, `src/NaNReserve.sol:168` | `newOracle` (user-controlled) | `_setOracle → newOracle.price/redemptionPrice`; replaces `oracle` |
| NaNReserve | `setDebtRatios`, `src/NaNReserve.sol:172` | `minBps`, `targetBps`, `maxBps` (user-controlled) | `_setDebtRatios`; three ordered ratio parameters |
| NaNReserve | `setFees`, `src/NaNReserve.sol:176` | `mintBps`, `redeemBps` (user-controlled) | `_setFees`; two fee parameters |
| NaNReserve | `setRecoveryHalvingPeriod`, `src/NaNReserve.sol:181` | `newPeriod` (user-controlled) | Future `recoveryHalvingPeriod`; active episode unchanged |
| NaNReserve | `setInfWithdrawalDelay`, `src/NaNReserve.sol:191` | `newDelay` (user-controlled) | Future `infWithdrawalDelay`; opened cohort maturity unchanged |
| NaNReserve | `setInfWithdrawalEpoch`, `src/NaNReserve.sol:202` | `newLength` (user-controlled) | `currentWithdrawalEpoch`; duration and next schedule ID/start |
| NaNReserve | `transferOwnership`, inherited `Ownable2Step.sol:43` | `newOwner` (user-controlled) | `_pendingOwner` nomination/cancellation; owner retained until acceptance |

## Construction and Exclusions

Constructors validate dependencies and deploy immutable claim tokens; there are no public initializers or proxies. `renounceOwnership()` is a pure override that always reverts, and view-only price/health/preview methods are excluded. `fund()` is the sole junior deposit entry point; current source and freshly compiled ABI have no `recapitalize()` function.

OpenZeppelin source locations above resolve under `lib/openzeppelin-contracts/contracts/`; inherited bodies were checked solely to complete effective access and ABI coverage. Local-only faucets, mutable mock feeds/rates, and their inherited token operations are deliberately excluded from the production map.
