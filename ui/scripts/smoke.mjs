import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createPublicClient, createWalletClient, decodeEventLog, http, parseAbi, parseAbiItem, parseEther, toEventSelector } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'

const deployment = JSON.parse(await readFile(resolve(import.meta.dirname, '../public/local-deployment.json'), 'utf8'))
const rpcUrl = 'http://127.0.0.1:8545'
const account = privateKeyToAccount(process.env.LOCAL_PRIVATE_KEY ?? '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80')
const publicClient = createPublicClient({ chain: foundry, transport: http(rpcUrl) })
const walletClient = createWalletClient({ chain: foundry, account, transport: http(rpcUrl) })
const tokenAbi = parseAbi([
  'function faucet(uint256)', 'function approve(address,uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)', 'function setStEthPerToken(uint256)',
])
const feedAbi = parseAbi(['function setAnswer(int256)', 'function setUnavailable(bool)'])
const reserveAbi = parseAbi([
  'function nan() view returns (address)', 'function inf() view returns (address)',
  'function fund(uint256,uint256,address) returns (uint256)',
  'function mint(uint256,uint256,address) returns (uint256)',
  'function previewFund(uint256) view returns (uint256)',
  'function requestDefund(uint256) returns (uint256,uint256)',
  'function withdrawalMaturity(uint256,uint256) view returns (uint256)',
  'function settleDefundEpoch(uint256,uint256)',
  'function claimDefund(uint256,uint256,uint256,address) returns (uint256,uint256)',
  'function checkpointRecovery()',
  'function infPriceUsd() view returns (uint256)',
  'function recoveryFloorPriceUsd() view returns (uint256)',
  'function redemptionCollateralPriceUsd() view returns (uint256,bool)',
  'function redeem(uint256,uint256,address) returns (uint256)',
])
const requestEvent = parseAbiItem('event WithdrawalRequested(address indexed account, uint256 indexed series, uint256 indexed epoch, uint256 infIn)')
const read = (address, abi, functionName, args = []) => publicClient.readContract({ address, abi, functionName, args })
async function send(address, abi, functionName, args = []) {
  const { request } = await publicClient.simulateContract({ address, abi, functionName, args, account })
  const hash = await walletClient.writeContract(request)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success', `${functionName} should succeed`)
  process.stdout.write(`${functionName}: ${hash}\n`)
  return receipt
}

assert.equal(await publicClient.getChainId(), 31337)
assert.ok(await publicClient.getCode({ address: deployment.reserve }), 'reserve code missing: redeploy after restarting Anvil')
const nan = await read(deployment.reserve, reserveAbi, 'nan')
const inf = await read(deployment.reserve, reserveAbi, 'inf')
await send(deployment.collateral, tokenAbi, 'faucet', [parseEther('500')])
await send(deployment.collateral, tokenAbi, 'approve', [deployment.reserve, parseEther('500')])
await send(deployment.reserve, reserveAbi, 'fund', [parseEther('100'), 0n, account.address])
await send(deployment.reserve, reserveAbi, 'mint', [parseEther('180'), 0n, account.address])
assert.ok((await read(nan, tokenAbi, 'balanceOf', [account.address])) > 0n)

await send(deployment.collateral, tokenAbi, 'setStEthPerToken', [parseEther('1.01')])
await send(deployment.collateral, tokenAbi, 'setStEthPerToken', [parseEther('1')])
await send(deployment.feed, feedAbi, 'setAnswer', [150_000_000_000n])
await send(deployment.reserve, reserveAbi, 'checkpointRecovery')
assert.equal(await read(deployment.reserve, reserveAbi, 'infPriceUsd'), 0n)
assert.ok((await read(deployment.reserve, reserveAbi, 'recoveryFloorPriceUsd')) > 0n)
const recapQuote = await read(deployment.reserve, reserveAbi, 'previewFund', [parseEther('10')])
await send(deployment.reserve, reserveAbi, 'fund', [parseEther('10'), recapQuote, account.address])
assert.ok((await read(inf, tokenAbi, 'balanceOf', [account.address])) > parseEther('300000'))

await send(deployment.feed, feedAbi, 'setAnswer', [400_000_000_000n])
await send(inf, tokenAbi, 'approve', [deployment.reserve, parseEther('1000')])
const requestReceipt = await send(deployment.reserve, reserveAbi, 'requestDefund', [parseEther('1000')])
const requestLog = requestReceipt.logs.find(log => log.address.toLowerCase() === deployment.reserve.toLowerCase() && log.topics[0] === toEventSelector(requestEvent))
assert.ok(requestLog, 'withdrawal event missing')
const { args: { series, epoch } } = decodeEventLog({ abi: [requestEvent], data: requestLog.data, topics: requestLog.topics })
const maturity = await read(deployment.reserve, reserveAbi, 'withdrawalMaturity', [series, epoch])
await publicClient.request({ method: 'evm_setNextBlockTimestamp', params: [`0x${maturity.toString(16)}`] })
await publicClient.request({ method: 'evm_mine' })
await send(deployment.reserve, reserveAbi, 'settleDefundEpoch', [series, epoch])
await send(deployment.reserve, reserveAbi, 'claimDefund', [series, epoch, 0n, account.address])

await send(deployment.feed, feedAbi, 'setUnavailable', [true])
const [, fallbackUsed] = await read(deployment.reserve, reserveAbi, 'redemptionCollateralPriceUsd')
assert.equal(fallbackUsed, true)
await send(deployment.reserve, reserveAbi, 'redeem', [parseEther('1000'), 0n, account.address])
process.stdout.write('Local faucet → fund → mint → crash → insolvent fund → withdraw → fallback redeem: PASS\n')
