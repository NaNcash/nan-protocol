import { spawnSync } from 'node:child_process'
import { readFile, writeFile, mkdir, access } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { homedir } from 'node:os'

const repo = resolve(import.meta.dirname, '..')
const require = createRequire(resolve(repo, 'ui/package.json'))
const { createPublicClient, http, getAddress, parseAbi, decodeEventLog } = require('viem')
const { sepolia } = require('viem/chains')
const manifestPath = resolve(repo, process.env.SEPOLIA_MANIFEST_PATH ?? 'ui/public/sepolia-deployment.json')
const broadcastPath = resolve(repo, 'broadcast/DeploySepolia.s.sol/11155111/run-latest.json')

async function main() {
  const flags = new Set(process.argv.slice(2))
  for (const flag of flags) {
    if (!['--broadcast', '--manifest-only'].includes(flag)) throw new Error(`Unknown option: ${flag}`)
  }
  if (flags.size > 1) throw new Error('Choose --broadcast or --manifest-only')
  const rpcUrl = process.env.SEPOLIA_RPC_URL
  if (!rpcUrl) throw new Error('Set SEPOLIA_RPC_URL in .env.sepolia')
  const url = new URL(rpcUrl)
  if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Use an HTTP(S) Sepolia RPC URL')
  const client = createPublicClient({ chain: sepolia, transport: http(rpcUrl) })
  const chainId = await client.getChainId()
  if (chainId !== sepolia.id) throw new Error(`Expected Sepolia ${sepolia.id}, got ${chainId}; refusing deployment`)

  if (!flags.has('--manifest-only')) {
    const accountName = process.env.SEPOLIA_ACCOUNT || 'sepolia-deployer'
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(accountName)) throw new Error('SEPOLIA_ACCOUNT must be a Foundry keystore account name')
    const keystorePath = process.env.SEPOLIA_KEYSTORE_PATH ? resolve(process.env.SEPOLIA_KEYSTORE_PATH) : undefined
    await access(keystorePath ?? resolve(homedir(), '.foundry/keystores', accountName))
    const walletOption = keystorePath ? ['--keystore', keystorePath] : ['--account', accountName]
    const passwordFile = process.env.SEPOLIA_PASSWORD_FILE || process.env.ETH_PASSWORD
    const configuredAddress = process.env.SEPOLIA_DEPLOYER ? getAddress(process.env.SEPOLIA_DEPLOYER) : undefined
    if (passwordFile) await access(resolve(passwordFile))
    // Simulation can use a public address; signing always derives it from the actual keystore.
    let address = configuredAddress
    if (passwordFile && (flags.has('--broadcast') || !address)) {
      const walletArgs = ['wallet', 'address', ...walletOption]
      if (passwordFile) walletArgs.push('--password-file', resolve(passwordFile))
      const wallet = spawnSync('cast', walletArgs, { cwd: repo, env: process.env, stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8' })
      if (wallet.error) throw wallet.error
      if (wallet.status !== 0) throw new Error('Unable to unlock the deployment keystore')
      address = getAddress(wallet.stdout.trim())
      if (configuredAddress && address !== configuredAddress) throw new Error('SEPOLIA_DEPLOYER does not match the selected keystore')
    }
    // In an interactive terminal, Forge unlocks the selected account itself exactly once.
    if (!address && !passwordFile && !process.stdin.isTTY) {
      throw new Error('Run make sepolia-deploy in your terminal for Foundry’s hidden password prompt. A dry run without signing can use SEPOLIA_DEPLOYER=<public address>.')
    }
    // Public development keys must never become a public-chain deployment identity.
    const anvilAccounts = new Set([
      '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
      '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
      '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
      '0x90f79bf6eb2c4f870365e785982e1f101e93b906',
      '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65',
      '0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc',
      '0x976ea74026e726554db657fa54763abd0c3a0aa9',
      '0x14dc79964da2c08b23698b3d3cc7ca32193d9955',
      '0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f',
      '0xa0ee7a142d267c1f36714e4a8f75612f20a79720',
    ])
    if (address && anvilAccounts.has(address.toLowerCase())) {
      throw new Error('Refusing a public development key; use a fresh dedicated Sepolia wallet')
    }
    if (process.env.SEPOLIA_AUTHORIZER) getAddress(process.env.SEPOLIA_AUTHORIZER)
    if (flags.has('--broadcast')) {
      let exists = false
      try { await access(manifestPath); exists = true } catch {}
      if (exists) throw new Error('A Sepolia manifest already exists; archive it before intentionally deploying another stack')
      if (address && await client.getBalance({ address }) === 0n) {
        throw new Error('Fund the deployment wallet with native Sepolia ETH for gas first')
      }
    }
    console.log(`Sepolia deployer: ${address ?? 'resolved by Foundry after unlock'} (keystore: ${accountName})`)
    console.log(flags.has('--broadcast') ? 'Broadcasting the playground deployment.' : 'Simulating only; no transactions will be sent.')
    const args = ['script', 'script/DeploySepolia.s.sol:DeploySepolia', '--rpc-url', rpcUrl, '--chain', String(sepolia.id)]
    if (address) args.push('--sender', address)
    if (flags.has('--broadcast')) {
      // This makes Forge re-estimate every transaction through eth_estimateGas immediately
      // before sending it. Its local EVM still uses the older pre-Glamsterdam gas schedule.
      args.push('--broadcast', '--slow', '--skip-simulation', ...walletOption)
      if (passwordFile) args.push('--password-file', resolve(passwordFile))
      if (process.env.ETHERSCAN_API_KEY) args.push('--verify')
    } else if (!address) {
      args.push(...walletOption)
    }
    const { PRIVATE_KEY, SEPOLIA_DEPLOYER, ...forgeEnv } = process.env
    if (address) forgeEnv.SEPOLIA_DEPLOYER = address
    const result = spawnSync('forge', args, { cwd: repo, env: forgeEnv, stdio: 'inherit' })
    if (result.error) throw result.error
    if (result.status !== 0) throw new Error('Forge failed. If transactions were sent, inspect broadcast records before retrying; use sepolia-manifest after completing the deployment.')
    if (!flags.has('--broadcast')) return
  }

  const broadcast = JSON.parse(await readFile(broadcastPath, 'utf8'))
  if (broadcast.transactions?.length !== 8 || broadcast.receipts?.length !== 8
      || broadcast.receipts.some(receipt => BigInt(receipt.status) !== 1n)) {
    throw new Error('Broadcast has missing or failed receipts; refusing to publish the UI manifest')
  }
  const receiptHashes = new Set(broadcast.receipts.map(receipt => receipt.transactionHash.toLowerCase()))
  if (receiptHashes.size !== 8 || broadcast.transactions.some(tx => !receiptHashes.has(tx.hash?.toLowerCase()))) {
    throw new Error('Every planned deployment transaction must have a successful receipt')
  }
  // Confirm every recorded receipt on this RPC, including the final bootstrap fund.
  for (const recorded of broadcast.receipts) {
    const actual = await client.getTransactionReceipt({ hash: recorded.transactionHash })
    if (actual.status !== 'success' || actual.blockHash.toLowerCase() !== recorded.blockHash.toLowerCase()) {
      throw new Error('Broadcast receipts do not match the connected chain')
    }
  }
  const addressOf = name => {
    const address = broadcast.transactions.find(tx => tx.contractName === name)?.contractAddress
    if (!address) throw new Error(`Missing ${name} deployment address`)
    return getAddress(address)
  }
  const deployment = {
    chainId,
    collateral: addressOf('PlaygroundETH'),
    feed: addressOf('PlaygroundPriceFeed'),
    fallbackOracle: addressOf('PlaygroundFallbackOracle'),
    oracle: addressOf('WstEthUsdOracle'),
    reserve: addressOf('NaNReserve'),
    deploymentBlock: Number(BigInt(broadcast.receipts[0].blockNumber)),
  }
  const bootstrapAbi = parseAbi(['event Funded(address indexed caller, address indexed recipient, uint256 collateralIn, uint256 infOut)'])
  const bootstrapReceipt = broadcast.receipts.find(receipt => receipt.logs.some(log => {
    if (log.address.toLowerCase() !== deployment.reserve.toLowerCase()) return false
    try {
      const { args } = decodeEventLog({ abi: bootstrapAbi, data: log.data, topics: log.topics })
      return args.collateralIn === 100n * 10n ** 18n && args.infOut === 300_000n * 10n ** 18n
        && getAddress(args.caller) === getAddress(args.recipient)
    } catch { return false }
  }))
  if (!bootstrapReceipt) throw new Error('Missing the successful 100 pgETH / 300,000 INF bootstrap event')
  for (const name of ['collateral', 'feed', 'fallbackOracle', 'oracle', 'reserve']) {
    const code = await client.getCode({ address: deployment[name] })
    if (!code || code === '0x') throw new Error(`Missing deployed bytecode for ${name}`)
  }
  const abi = parseAbi([
    'function owner() view returns (address)',
    'function collateral() view returns (address)',
    'function oracle() view returns (address)',
    'function nan() view returns (address)',
    'function inf() view returns (address)',
  ])
  const read = (address, functionName) => client.readContract({ address, abi, functionName })
  const reserveRead = functionName => read(deployment.reserve, functionName)
  const [owner, collateral, oracle, nan, inf] = await Promise.all(['owner', 'collateral', 'oracle', 'nan', 'inf'].map(reserveRead))
  if (getAddress(collateral) !== deployment.collateral || getAddress(oracle) !== deployment.oracle) throw new Error('Reserve wiring does not match the deployment')
  for (const name of ['collateral', 'feed', 'fallbackOracle']) {
    if (getAddress(await read(deployment[name], 'owner')) !== getAddress(owner)) throw new Error(`Controller mismatch for ${name}`)
  }
  Object.assign(deployment, { authorizer: getAddress(owner), nan: getAddress(nan), inf: getAddress(inf) })
  await mkdir(resolve(repo, 'ui/public'), { recursive: true })
  await writeFile(manifestPath, `${JSON.stringify(deployment, null, 2)}\n`)
  console.log(`Validated Sepolia UI manifest written to ${manifestPath}`)
}

main().catch(error => {
  // RPC/library errors may contain credential-bearing URLs. Keep diagnostics private.
  const message = error.shortMessage ?? error.message ?? 'Deployment failed'
  process.stderr.write(`${message.replace(/https?:\/\/[^\s"'<>]+/g, '[RPC URL]')}\n`)
  process.exitCode = 1
})
