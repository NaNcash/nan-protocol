import { spawnSync } from 'node:child_process'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'

const repo = resolve(import.meta.dirname, '..')
const rpcUrl = process.env.LOCAL_RPC_URL ?? 'http://127.0.0.1:8545'
const deployerKey = process.env.LOCAL_PRIVATE_KEY ?? '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

async function rpc(method, params = []) {
  const response = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  if (!response.ok) throw new Error(`RPC returned HTTP ${response.status}`)
  const result = await response.json()
  if (result.error) throw new Error(result.error.message)
  return result.result
}

async function main() {
  const url = new URL(rpcUrl)
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(url.hostname)) {
    throw new Error('Local deployment only accepts a loopback HTTP RPC URL')
  }
  const chainId = Number(BigInt(await rpc('eth_chainId')))
  if (chainId !== 31337) throw new Error(`Expected Anvil chain 31337, got ${chainId}`)

  const result = spawnSync('forge', [
    'script', 'script/DeployLocal.s.sol:DeployLocal',
    '--rpc-url', rpcUrl, '--broadcast',
  ], {
    cwd: repo,
    env: { ...process.env, PRIVATE_KEY: deployerKey },
    encoding: 'utf8',
  })
  process.stdout.write(result.stdout ?? '')
  process.stderr.write(result.stderr ?? '')
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`Local deployment failed with exit ${result.status}`)

  const broadcast = JSON.parse(await readFile(resolve(repo, 'broadcast/DeployLocal.s.sol/31337/run-latest.json'), 'utf8'))
  const addressOf = (name) => {
    const address = broadcast.transactions.find(tx => tx.contractName === name)?.contractAddress
    if (!/^0x[0-9a-fA-F]{40}$/.test(address ?? '')) throw new Error(`Missing ${name} address in broadcast`)
    return address
  }
  const deployment = {
    chainId,
    collateral: addressOf('LocalWstETH'),
    feed: addressOf('LocalStEthUsdFeed'),
    fallbackOracle: addressOf('LocalFallbackOracle'),
    oracle: addressOf('WstEthUsdOracle'),
    reserve: addressOf('NaNReserve'),
    deploymentBlock: Number(BigInt(broadcast.receipts[0].blockNumber)),
  }
  const destination = resolve(repo, 'ui/public/local-deployment.json')
  await mkdir(resolve(repo, 'ui/public'), { recursive: true })
  await writeFile(destination, `${JSON.stringify(deployment, null, 2)}\n`)
  process.stdout.write(`Local UI deployment written to ${destination}\n`)
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`)
  process.exitCode = 1
})
