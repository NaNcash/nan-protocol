// Isolated Anvil adversarial run. Start Anvil on port 8546 and deploy with
// DeployLocal before running; this script refuses the normal UI port 8545.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createPublicClient, createWalletClient, decodeEventLog, http, parseAbi, parseAbiItem, parseEther, toEventSelector } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'

const rpcUrl = process.env.LOCAL_STRESS_RPC_URL ?? 'http://127.0.0.1:8546'
const url = new URL(rpcUrl)
if (!['127.0.0.1', 'localhost'].includes(url.hostname) || url.port === '8545') {
  throw new Error('Stress run requires an isolated loopback RPC, not the UI chain on port 8545')
}
const broadcast = JSON.parse(await readFile(resolve(import.meta.dirname, '../../broadcast/DeployLocal.s.sol/31337/run-latest.json'), 'utf8'))
const addressOf = name => {
  const address = broadcast.transactions.find(tx => tx.contractName === name)?.contractAddress
  assert.match(address ?? '', /^0x[0-9a-fA-F]{40}$/)
  return address
}
const collateral = addressOf('LocalWstETH')
const feed = addressOf('LocalStEthUsdFeed')
const fallback = addressOf('LocalFallbackOracle')
const reserve = addressOf('NaNReserve')
const publicClient = createPublicClient({ chain: foundry, transport: http(rpcUrl) })
const reserveAbi = parseAbi([
  'function nan() view returns (address)', 'function inf() view returns (address)',
  'function reserveCollateral() view returns (uint256)', 'function claimableWithdrawalCollateral() view returns (uint256)',
  'function debtUsd() view returns (uint256)', 'function debtRatioBps() view returns (uint256)',
  'function infPriceUsd() view returns (uint256)', 'function health() view returns (uint8)',
  'function fund(uint256,uint256,address) returns (uint256)',
  'function mint(uint256,uint256,address) returns (uint256)',
  'function redeem(uint256,uint256,address) returns (uint256)',
  'function requestDefund(uint256) returns (uint256,uint256)',
  'function withdrawalMaturity(uint256,uint256) view returns (uint256)',
  'function withdrawalExpiry(uint256,uint256) view returns (uint256)',
  'function settleDefundEpoch(uint256,uint256)',
  'function expireDefundEpoch(uint256,uint256)',
  'function claimDefund(uint256,uint256,uint256,address) returns (uint256,uint256)',
  'function checkpointRecovery()',
])
const tokenAbi = parseAbi([
  'function faucet(uint256)', 'function approve(address,uint256) returns (bool)',
  'function transfer(address,uint256) returns (bool)',
  'function totalSupply() view returns (uint256)', 'function balanceOf(address) view returns (uint256)',
])
const feedAbi = parseAbi(['function setAnswer(int256)', 'function setUnavailable(bool)'])
const fallbackAbi = parseAbi(['function setPrice(uint256)'])
const withdrawalEvent = parseAbiItem('event WithdrawalRequested(address indexed account,uint256 indexed series,uint256 indexed epoch,uint256 infIn)')
const read = (address, abi, functionName, args = []) => publicClient.readContract({ address, abi, functionName, args })
const wallets = Array.from({ length: 50 }, (_, i) => {
  const account = privateKeyToAccount(`0x${BigInt(1001 + i).toString(16).padStart(64, '0')}`)
  return { account, client: createWalletClient({ account, chain: foundry, transport: http(rpcUrl) }) }
})
let successful = 0
let expectedReverts = 0
async function send(wallet, address, abi, functionName, args = []) {
  const { request } = await publicClient.simulateContract({ address, abi, functionName, args, account: wallet.account })
  const hash = await wallet.client.writeContract(request)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success', `${functionName}: ${hash}`)
  successful++
  return receipt
}
async function mustRevert(wallet, address, abi, functionName, args = []) {
  await assert.rejects(publicClient.simulateContract({ address, abi, functionName, args, account: wallet.account }))
  expectedReverts++
}
async function state(label, nan, inf) {
  const [debt, reserveBalance, claimable, nanSupply, infSupply, ratio, health] = await Promise.all([
    read(reserve, reserveAbi, 'debtUsd'), read(reserve, reserveAbi, 'reserveCollateral'),
    read(reserve, reserveAbi, 'claimableWithdrawalCollateral'), read(nan, tokenAbi, 'totalSupply'),
    read(inf, tokenAbi, 'totalSupply'), read(reserve, reserveAbi, 'debtRatioBps'),
    read(reserve, reserveAbi, 'health'),
  ])
  assert.equal(debt, nanSupply, 'NaN supply must equal recorded debt')
  assert.ok(debt === 0n || infSupply > 0n, 'NaN debt must retain junior capital')
  assert.equal((await read(collateral, tokenAbi, 'balanceOf', [reserve])), reserveBalance + claimable)
  console.log(`${label}: debt=${Number(debt / parseEther('1'))} reserveWstETH=${Number(reserveBalance / parseEther('1'))} ratioBps=${ratio} health=${health} INF=${Number(infSupply / parseEther('1'))}`)
}

assert.equal(await publicClient.getChainId(), 31337)
assert.ok(await publicClient.getCode({ address: reserve }), 'Reserve missing; deploy on isolated Anvil first')
const nan = await read(reserve, reserveAbi, 'nan')
const inf = await read(reserve, reserveAbi, 'inf')
assert.equal(await read(nan, tokenAbi, 'totalSupply'), 0n, 'Refusing a non-fresh deployment')
assert.equal(await read(inf, tokenAbi, 'totalSupply'), 0n, 'Refusing a non-fresh deployment')

// 50 independently keyed users; all become juniors, 20 also become minters.
for (const wallet of wallets) {
  await publicClient.request({ method: 'anvil_setBalance', params: [wallet.account.address, '0x8ac7230489e80000'] })
  await send(wallet, collateral, tokenAbi, 'faucet', [parseEther('100')])
  await send(wallet, collateral, tokenAbi, 'approve', [reserve, parseEther('100')])
}
for (const wallet of wallets.slice(0, 12)) {
  await send(wallet, reserve, reserveAbi, 'fund', [parseEther('10'), 0n, wallet.account.address])
}
for (const wallet of wallets.slice(12, 32)) await send(wallet, reserve, reserveAbi, 'mint', [parseEther('8'), 0n, wallet.account.address])
for (const wallet of wallets.slice(12)) await send(wallet, reserve, reserveAbi, 'fund', [parseEther('0.1'), 0n, wallet.account.address])
for (const wallet of wallets) await send(wallet, inf, tokenAbi, 'approve', [reserve, parseEther('1000000')])
await state('after 70 deposits', nan, inf)

// Split one senior holder's claim into 16 independently controlled accounts.
for (const wallet of wallets.slice(32, 48)) await send(wallets[12], nan, tokenAbi, 'transfer', [wallet.account.address, parseEther('1000')])

// All 50 juniors request withdrawal in the same cohort, then experience a large price spike.
let series, epoch
for (const wallet of wallets) {
  const infBalance = await read(inf, tokenAbi, 'balanceOf', [wallet.account.address])
  const receipt = await send(wallet, reserve, reserveAbi, 'requestDefund', [infBalance / 2n])
  const log = receipt.logs.find(item => item.address.toLowerCase() === reserve.toLowerCase() && item.topics[0] === toEventSelector(withdrawalEvent))
  assert.ok(log)
  const parsed = decodeEventLog({ abi: [withdrawalEvent], data: log.data, topics: log.topics })
  series ??= parsed.args.series
  epoch ??= parsed.args.epoch
  assert.equal(parsed.args.series, series)
  assert.equal(parsed.args.epoch, epoch)
}
await send(wallets[49], feed, feedAbi, 'setAnswer', [450_000_000_000n])
const maturity = await read(reserve, reserveAbi, 'withdrawalMaturity', [series, epoch])
await publicClient.request({ method: 'evm_setNextBlockTimestamp', params: [`0x${maturity.toString(16)}`] })
await publicClient.request({ method: 'evm_mine' })
await send(wallets[49], reserve, reserveAbi, 'settleDefundEpoch', [series, epoch])
for (const wallet of wallets) await send(wallet, reserve, reserveAbi, 'claimDefund', [series, epoch, 0n, wallet.account.address])
await state('after price-spike withdrawals', nan, inf)

// Crash, incremental recapitalization, then senior redemptions across holders.
await send(wallets[49], feed, feedAbi, 'setAnswer', [120_000_000_000n])
await send(wallets[49], reserve, reserveAbi, 'checkpointRecovery')
assert.equal(await read(reserve, reserveAbi, 'infPriceUsd'), 0n)
await state('after crash', nan, inf)
for (const wallet of wallets.slice(40, 48)) await send(wallet, reserve, reserveAbi, 'fund', [parseEther('5'), 0n, wallet.account.address])
for (const wallet of wallets.slice(13, 32)) {
  const balance = await read(nan, tokenAbi, 'balanceOf', [wallet.account.address])
  await send(wallet, reserve, reserveAbi, 'redeem', [balance / 3n, 0n, wallet.account.address])
}
await state('after recap and pro-rata redemptions', nan, inf)

// Primary outage, then simultaneous failure of both feeds. Restore and prove liveness.
await send(wallets[49], feed, feedAbi, 'setUnavailable', [true])
for (const wallet of wallets.slice(32, 40)) {
  const balance = await read(nan, tokenAbi, 'balanceOf', [wallet.account.address])
  await send(wallet, reserve, reserveAbi, 'redeem', [balance, 0n, wallet.account.address])
}
await send(wallets[49], fallback, fallbackAbi, 'setPrice', [0n])
await mustRevert(wallets[40], reserve, reserveAbi, 'redeem', [parseEther('100'), 0n, wallets[40].account.address])
await mustRevert(wallets[48], reserve, reserveAbi, 'fund', [parseEther('1'), 0n, wallets[48].account.address])
await mustRevert(wallets[48], reserve, reserveAbi, 'mint', [parseEther('1'), 0n, wallets[48].account.address])
// Missed settlement is not an indefinite INF lock, even with both oracles down.
const expiredRequest = await send(wallets[0], reserve, reserveAbi, 'requestDefund', [parseEther('1')])
const expiredLog = expiredRequest.logs.find(item => item.address.toLowerCase() === reserve.toLowerCase() && item.topics[0] === toEventSelector(withdrawalEvent))
assert.ok(expiredLog)
const expired = decodeEventLog({ abi: [withdrawalEvent], data: expiredLog.data, topics: expiredLog.topics }).args
const expiry = await read(reserve, reserveAbi, 'withdrawalExpiry', [expired.series, expired.epoch])
await publicClient.request({ method: 'evm_setNextBlockTimestamp', params: [`0x${expiry.toString(16)}`] })
await publicClient.request({ method: 'evm_mine' })
await send(wallets[1], reserve, reserveAbi, 'expireDefundEpoch', [expired.series, expired.epoch])
await send(wallets[0], reserve, reserveAbi, 'claimDefund', [expired.series, expired.epoch, 0n, wallets[0].account.address])
await send(wallets[49], fallback, fallbackAbi, 'setPrice', [parseEther('3000')])
await send(wallets[49], feed, feedAbi, 'setUnavailable', [false])
await send(wallets[49], feed, feedAbi, 'setAnswer', [300_000_000_000n])
await send(wallets[48], reserve, reserveAbi, 'fund', [parseEther('1'), 0n, wallets[48].account.address])
const seniorBalance = await read(nan, tokenAbi, 'balanceOf', [wallets[31].account.address])
await send(wallets[31], reserve, reserveAbi, 'redeem', [seniorBalance / 4n, 0n, wallets[31].account.address])
await state('after oracle restoration', nan, inf)
await send(wallets[49], reserve, reserveAbi, 'fund', [parseEther('40'), 0n, wallets[49].account.address])
await send(wallets[32], reserve, reserveAbi, 'mint', [parseEther('1'), 0n, wallets[32].account.address])
await state('after full mint recovery', nan, inf)
console.log(`PASS: ${successful} successful transactions across 50 wallets; ${expectedReverts} expected outage reverts; funding, minting, and redemption recovered`)
