import './style.css'
import {
  createPublicClient, createWalletClient, custom, formatUnits, getAddress, http, isAddress,
  parseAbi, parseAbiItem, parseUnits,
} from 'viem'
import { foundry } from 'viem/chains'

const $ = id => document.getElementById(id)
const WAD = 10n ** 18n
const reserveAbi = parseAbi([
  'function nan() view returns (address)',
  'function inf() view returns (address)',
  'function owner() view returns (address)',
  'function collateralPriceUsd() view returns (uint256)',
  'function redemptionCollateralPriceUsd() view returns (uint256, bool)',
  'function reserveUsd() view returns (uint256)',
  'function reserveCollateral() view returns (uint256)',
  'function debtUsd() view returns (uint256)',
  'function debtRatioBps() view returns (uint256)',
  'function health() view returns (uint8)',
  'function infPriceUsd() view returns (uint256)',
  'function fundingPriceUsd() view returns (uint256)',
  'function recoveryFloorPriceUsd() view returns (uint256)',
  'function mintFeeBps() view returns (uint256)',
  'function redeemFeeBps() view returns (uint256)',
  'function infWithdrawalDelay() view returns (uint256)',
  'function recoveryHalvingPeriod() view returns (uint256)',
  'function previewFund(uint256) view returns (uint256)',
  'function currentWithdrawalEpoch() view returns (uint256, uint256)',
  'function withdrawalEpochs(uint256, uint256) view returns (address, uint256, uint256, uint256, bool, uint64)',
  'function withdrawalRequests(uint256, uint256, address) view returns (uint256, uint256)',
  'function fund(uint256, uint256, address) returns (uint256)',
  'function mint(uint256, uint256, address) returns (uint256)',
  'function redeem(uint256, uint256, address) returns (uint256)',
  'function requestDefund(uint256) returns (uint256, uint256)',
  'function settleDefundEpoch(uint256, uint256)',
  'function expireDefundEpoch(uint256, uint256)',
  'function claimDefund(uint256, uint256, uint256, address) returns (uint256, uint256)',
  'function checkpointRecovery()',
  'function setInfWithdrawalDelay(uint256)',
  'function setRecoveryHalvingPeriod(uint256)',
])
const tokenAbi = parseAbi([
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
])
const collateralAbi = parseAbi([
  'function faucet(uint256)',
  'function setStEthPerToken(uint256)',
  'function stEthPerToken() view returns (uint256)',
])
const feedAbi = parseAbi([
  'function answer() view returns (int256)',
  'function stale() view returns (bool)',
  'function unavailable() view returns (bool)',
  'function setAnswer(int256)',
  'function setStale(bool)',
  'function setUnavailable(bool)',
])
const fallbackAbi = parseAbi(['function priceValue() view returns (uint256)', 'function setPrice(uint256)'])
const requestEvent = parseAbiItem('event WithdrawalRequested(address indexed account, uint256 indexed series, uint256 indexed epoch, uint256 infIn)')

const publicClient = createPublicClient({ chain: foundry, transport: http('/rpc') })
let deployment
let tokens
let tokenDetails
let walletClient
let account
let busy = false
let refreshing = false
let current = {}

function notice(message, error = false) {
  $('notice').textContent = message
  $('notice').classList.toggle('error', error)
}

function short(address) { return `${address.slice(0, 6)}…${address.slice(-4)}` }
function amount(value, decimals = 18, digits = 3) {
  if (value === null || value === undefined) return '—'
  const number = Number(formatUnits(value, decimals))
  if (number > 0 && number < 10 ** -digits) return `<${(10 ** -digits).toFixed(digits)}`
  return Number.isFinite(number) ? number.toLocaleString(undefined, { maximumFractionDigits: digits }) : 'Very large'
}
function usd(value, digits = 2) { return value === null ? '—' : `$${amount(value, 18, digits)}` }
function date(seconds) { return new Date(Number(seconds) * 1000).toLocaleString() }
function formValue(form, name, decimals = 18) {
  const value = new FormData(form).get(name)?.toString() ?? ''
  const parsed = parseUnits(value, decimals)
  if (parsed <= 0n) throw new Error('Enter an amount greater than zero')
  return parsed
}
function setText(id, text) { $(id).textContent = text }

async function loadTokenDetails() {
  const addresses = { collateral: deployment.collateral, nan: tokens.nan, inf: tokens.inf }
  const entries = await Promise.all(Object.entries(addresses).map(async ([key, rawAddress]) => {
    const address = getAddress(rawAddress)
    const [symbol, decimals] = await Promise.all([
      read(address, tokenAbi, 'symbol'),
      read(address, tokenAbi, 'decimals'),
    ])
    setText(`token-address-${key}`, address)
    setText(`token-symbol-${key}`, symbol)
    return [key, { address, symbol, decimals }]
  }))
  tokenDetails = Object.fromEntries(entries)
}

async function read(address, abi, functionName, args = []) {
  return publicClient.readContract({ address, abi, functionName, args })
}
async function reserveRead(functionName, args = []) { return read(deployment.reserve, reserveAbi, functionName, args) }
async function optional(task) { try { return await task() } catch { return null } }

function provider() {
  if (!window.ethereum) throw new Error('Install an injected wallet such as MetaMask, then import an Anvil test account')
  return window.ethereum
}

async function verifyWalletRpc() {
  const injected = provider()
  try {
    if (await injected.request({ method: 'eth_chainId' }) !== '0x7a69') {
      throw new Error('Wallet is not on chain 31337')
    }
    const block = await injected.request({ method: 'eth_getBlockByNumber', params: ['latest', false] })
    if (!block?.number) throw new Error('Wallet RPC returned no latest block')
  } catch (error) {
    throw new Error(`Your wallet cannot reach the local Anvil RPC. In MetaMask → Settings → Networks, set the RPC URL for chain 31337 to http://127.0.0.1:8545, keep make local-chain running, then reconnect. The UI cannot replace the RPC URL of a network already saved in MetaMask. (${error.shortMessage ?? error.message ?? String(error)})`)
  }
}

async function ensureAnvilWallet() {
  const injected = provider()
  const desired = '0x7a69'
  const actual = await injected.request({ method: 'eth_chainId' })
  if (actual !== desired) {
    try {
      await injected.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: desired }] })
    } catch (error) {
      if (error.code !== 4902) throw error
      await injected.request({ method: 'wallet_addEthereumChain', params: [{
        chainId: desired, chainName: 'Anvil Local 31337',
        rpcUrls: ['http://127.0.0.1:8545'], nativeCurrency: { name: 'Local Ether', symbol: 'ETH', decimals: 18 },
      }] })
    }
  }
  const accounts = await injected.request({ method: 'eth_requestAccounts' })
  if (!accounts?.length) throw new Error('No account selected in wallet')
  await verifyWalletRpc()
  account = accounts[0]
  walletClient = createWalletClient({ account, chain: foundry, transport: custom(injected) })
  setText('wallet-label', `Wallet ${short(account)}`)
  $('connect').textContent = short(account)
}

async function write(address, abi, functionName, args = []) {
  if (!deployment) throw new Error('Deploy contracts first with make local-deploy')
  if (!account || !walletClient) await ensureAnvilWallet()
  await verifyWalletRpc()
  if (await publicClient.getBalance({ address: account }) === 0n) {
    throw new Error('This wallet has no local ETH for gas. Import a funded Anvil test account from the make local-chain terminal.')
  }
  notice(`Confirm ${functionName} in your wallet…`)
  const hash = await walletClient.writeContract({ address, abi, functionName, args, account, chain: foundry })
  notice(`${functionName} submitted · ${short(hash)} · waiting for confirmation…`)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted on-chain`)
  return receipt
}
async function reserveWrite(functionName, args = []) { return write(deployment.reserve, reserveAbi, functionName, args) }
async function approveIfNeeded(token, value) {
  const allowance = await read(token, tokenAbi, 'allowance', [account, deployment.reserve])
  if (allowance < value) await write(token, tokenAbi, 'approve', [deployment.reserve, value])
}
async function execute(label, action) {
  if (busy) return
  busy = true
  document.querySelectorAll('button').forEach(button => { if (button.id !== 'refresh') button.disabled = true })
  try {
    const result = await action()
    notice(typeof result === 'string' ? result : `${label} completed on Anvil.`)
    await refresh()
  } catch (error) {
    notice(error.shortMessage ?? error.message ?? String(error), true)
  } finally {
    busy = false
    document.querySelectorAll('button').forEach(button => { button.disabled = false })
  }
}

async function localRpc(method, params = []) {
  const response = await fetch('/rpc', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }) })
  if (!response.ok) throw new Error(`Local RPC returned ${response.status}`)
  const body = await response.json()
  if (body.error) throw new Error(body.error.message)
  return body.result
}
async function advanceTo(timestamp) {
  const now = (await publicClient.getBlock()).timestamp
  if (timestamp <= now) return
  await localRpc('evm_setNextBlockTimestamp', [`0x${timestamp.toString(16)}`])
  await localRpc('evm_mine')
}
async function advanceBy(seconds) {
  await advanceTo((await publicClient.getBlock()).timestamp + BigInt(seconds))
}

function requestButton(text, callback) {
  const button = document.createElement('button')
  button.type = 'button'
  button.textContent = text
  button.className = 'secondary'
  button.addEventListener('click', callback)
  return button
}

async function showWithdrawals(now) {
  const container = $('withdrawals')
  container.replaceChildren()
  if (!account) { container.textContent = 'Connect a wallet to see its requests.'; return }
  const events = await publicClient.getLogs({
    address: deployment.reserve,
    event: requestEvent,
    args: { account },
    fromBlock: BigInt(deployment.deploymentBlock),
  })
  let shown = 0
  for (const event of [...events].reverse()) {
    const { series, epoch } = event.args
    const [, requested] = await reserveRead('withdrawalRequests', [series, epoch, account])
    if (requested === 0n) continue
    shown++
    const [, , , , settled, maturity] = await reserveRead('withdrawalEpochs', [series, epoch])
    const row = document.createElement('div')
    row.className = 'withdrawal'
    const heading = document.createElement('strong')
    heading.textContent = `Epoch ${epoch} · ${amount(requested)} INF`
    const detail = document.createElement('span')
    detail.textContent = settled ? 'Settled — claim now' : `Matures ${date(maturity)}`
    row.append(heading, detail)
    const actions = document.createElement('div')
    actions.className = 'inline-actions'
    const expiry = BigInt(maturity) + 86_400n
    if (settled) {
      actions.append(requestButton('Claim', () => execute('Claim', async () => reserveWrite('claimDefund', [series, epoch, 0n, account]))))
    } else if (now >= expiry) {
      actions.append(requestButton('Expire & refund', () => execute('Expire cohort', async () => reserveWrite('expireDefundEpoch', [series, epoch]))))
    } else if (now >= BigInt(maturity)) {
      actions.append(requestButton('Settle cohort', () => execute('Settle cohort', async () => reserveWrite('settleDefundEpoch', [series, epoch]))))
    } else {
      actions.append(requestButton('Jump to maturity', () => execute('Advance chain', async () => advanceTo(BigInt(maturity)))))
    }
    row.append(actions)
    container.append(row)
  }
  if (!shown) container.textContent = 'No open requests for this wallet.'
}

async function refresh() {
  if (refreshing || !deployment) return
  refreshing = true
  try {
    const chainId = await publicClient.getChainId()
    if (chainId !== 31337) throw new Error('The local RPC is not Anvil chain 31337')
    const bytecode = await publicClient.getCode({ address: deployment.reserve })
    if (!bytecode || bytecode === '0x') throw new Error('Anvil was restarted; run make local-deploy again')
    if (!tokens) tokens = { nan: await reserveRead('nan'), inf: await reserveRead('inf') }
    if (!tokenDetails) await loadTokenDetails()
    const block = await publicClient.getBlock()
    const [price, redeemQuote, reserveUsd, debt, ratio, health, infNav, fundingPrice, floor, owner, stale, unavailable] = await Promise.all([
      optional(() => reserveRead('collateralPriceUsd')),
      optional(() => reserveRead('redemptionCollateralPriceUsd')),
      optional(() => reserveRead('reserveUsd')),
      reserveRead('debtUsd'),
      optional(() => reserveRead('debtRatioBps')),
      optional(() => reserveRead('health')),
      optional(() => reserveRead('infPriceUsd')),
      optional(() => reserveRead('fundingPriceUsd')),
      optional(() => reserveRead('recoveryFloorPriceUsd')),
      reserveRead('owner'),
      read(deployment.feed, feedAbi, 'stale'),
      read(deployment.feed, feedAbi, 'unavailable'),
    ])
    current = { price, redeemQuote, reserveUsd, debt, ratio, health, infNav, fundingPrice, floor, owner, stale, unavailable }
    setText('chain-status', `Deployed reserve ${short(deployment.reserve)}`)
    setText('chain-time', date(block.timestamp))
    setText('collateral-price', usd(price))
    setText('reserve-usd', usd(reserveUsd, 0))
    setText('debt-usd', usd(debt, 0))
    setText('debt-ratio', ratio === null ? '—' : `${(Number(ratio) / 100).toFixed(2)}%`)
    setText('health', health === null ? 'Unavailable' : ['No debt', 'Healthy', 'Stressed', 'Insolvent'][Number(health)] ?? 'Unavailable')
    setText('inf-nav', usd(infNav, 6))
    setText('funding-price', usd(fundingPrice, 6))
    setText('recovery-floor', usd(floor, 6))
    setText('feed-status', unavailable ? 'Unavailable' : stale ? 'Stale' : 'Healthy')
    setText('redemption-source', redeemQuote === null ? 'Unavailable' : redeemQuote[1] ? 'Fallback' : 'Primary')
    setText('authorizer', owner)
    if (account) {
      const [eth, collateral, nan, inf] = await Promise.all([
        publicClient.getBalance({ address: account }),
        read(deployment.collateral, tokenAbi, 'balanceOf', [account]),
        read(tokens.nan, tokenAbi, 'balanceOf', [account]),
        read(tokens.inf, tokenAbi, 'balanceOf', [account]),
      ])
      setText('eth-balance', amount(eth))
      setText('collateral-balance', amount(collateral))
      setText('nan-balance', amount(nan))
      setText('inf-balance', amount(inf))
    }
    await showWithdrawals(block.timestamp)
  } catch (error) {
    notice(error.shortMessage ?? error.message ?? String(error), true)
    setText('chain-status', 'Local deployment unavailable')
  } finally {
    refreshing = false
  }
}

function onForm(id, label, action) {
  $(id).addEventListener('submit', event => {
    event.preventDefault()
    execute(label, () => action(event.currentTarget))
  })
}
function onClick(id, label, action) {
  $(id).addEventListener('click', () => execute(label, action))
}

function bindActions() {
  $('connect').addEventListener('click', () => execute('Wallet connection', ensureAnvilWallet))
  $('refresh').addEventListener('click', refresh)

  for (const key of ['collateral', 'nan', 'inf']) {
    onClick(`copy-${key}`, 'Address copy', async () => {
      const token = tokenDetails?.[key]
      if (!token) throw new Error('Wait for the local token addresses to load')
      try {
        await navigator.clipboard.writeText(token.address)
      } catch {
        throw new Error('Clipboard access is unavailable; select and copy the address shown above')
      }
      return `${token.symbol} address copied: ${token.address}`
    })
    onClick(`watch-${key}`, 'Token import', async () => {
      const token = tokenDetails?.[key]
      if (!token) throw new Error('Wait for the local token addresses to load')
      await ensureAnvilWallet()
      const accepted = await walletClient.watchAsset({
        type: 'ERC20',
        options: { address: token.address, symbol: token.symbol, decimals: token.decimals },
      })
      if (!accepted) throw new Error(`MetaMask did not accept the ${token.symbol} token suggestion`)
      return `${token.symbol} token suggestion sent to MetaMask; confirm it there if prompted.`
    })
  }

  onForm('eth-form', 'Local ETH top-up', async form => {
    const supplied = new FormData(form).get('address')?.toString().trim()
    const recipient = supplied || account
    if (!recipient || !isAddress(recipient)) throw new Error('Connect your wallet or enter a valid 0x wallet address')
    if (await publicClient.getChainId() !== 31337) throw new Error('Local ETH top-up only works on Anvil chain 31337')
    const minimum = 10n * WAD
    if (await publicClient.getBalance({ address: recipient }) < minimum) {
      await localRpc('anvil_setBalance', [recipient, `0x${minimum.toString(16)}`])
    }
    const balance = await publicClient.getBalance({ address: recipient })
    if (balance < minimum) {
      throw new Error('Anvil did not credit local ETH to this address')
    }
    return `${short(recipient)} has ${amount(balance)} local ETH for gas.`
  })
  onForm('faucet-form', 'Faucet', form => write(deployment.collateral, collateralAbi, 'faucet', [formValue(form, 'amount')]))
  onForm('fund-form', 'INF funding', async form => {
    if (!account) await ensureAnvilWallet()
    const collateralIn = formValue(form, 'amount')
    const quoted = await reserveRead('previewFund', [collateralIn])
    await approveIfNeeded(deployment.collateral, collateralIn)
    await reserveWrite('fund', [collateralIn, quoted * 995n / 1000n, account])
  })
  onForm('mint-form', 'NaN mint', async form => {
    if (!account) await ensureAnvilWallet()
    const collateralIn = formValue(form, 'amount')
    const price = await reserveRead('collateralPriceUsd')
    const fee = await reserveRead('mintFeeBps')
    const estimated = collateralIn * price / WAD * (10_000n - fee) / 10_000n
    await approveIfNeeded(deployment.collateral, collateralIn)
    await reserveWrite('mint', [collateralIn, estimated * 995n / 1000n, account])
  })
  onForm('redeem-form', 'NaN redemption', async form => {
    if (!account) await ensureAnvilWallet()
    const nanIn = formValue(form, 'amount')
    const [[price], debt, reserveCollateral, fee] = await Promise.all([
      reserveRead('redemptionCollateralPriceUsd'), reserveRead('debtUsd'),
      reserveRead('reserveCollateral'), reserveRead('redeemFeeBps'),
    ])
    // Value only unreserved collateral with the router's actual redemption quote.
    const backing = reserveCollateral * price / WAD
    const redemptionPrice = backing < debt ? backing * WAD / debt : WAD
    const gross = nanIn * redemptionPrice / WAD
    const net = backing > debt ? gross * (10_000n - fee) / 10_000n : gross
    const estimatedCollateral = net * WAD / price
    await reserveWrite('redeem', [nanIn, estimatedCollateral * 99n / 100n, account])
  })
  onForm('request-form', 'Withdrawal request', async form => {
    if (!account) await ensureAnvilWallet()
    const infIn = formValue(form, 'amount')
    await approveIfNeeded(tokens.inf, infIn)
    await reserveWrite('requestDefund', [infIn])
  })
  onForm('market-form', 'Price update', form => write(deployment.feed, feedAbi, 'setAnswer', [formValue(form, 'price', 8)]))
  onForm('rate-form', 'Rate update', form => write(deployment.collateral, collateralAbi, 'setStEthPerToken', [formValue(form, 'rate')]))
  onForm('fallback-form', 'Fallback update', form => {
    const value = new FormData(form).get('price')?.toString() ?? ''
    return write(deployment.fallbackOracle, fallbackAbi, 'setPrice', [parseUnits(value, 18)])
  })
  onForm('delay-form', 'Withdrawal delay update', form => {
    const days = BigInt(new FormData(form).get('days'))
    return reserveWrite('setInfWithdrawalDelay', [days * 86_400n])
  })
  onForm('halving-form', 'Recovery halving update', form => {
    const hours = BigInt(new FormData(form).get('hours'))
    return reserveWrite('setRecoveryHalvingPeriod', [hours * 3_600n])
  })
  onClick('crash', 'Crash', () => write(deployment.feed, feedAbi, 'setAnswer', [1_500n * 10n ** 8n]))
  onClick('rebound', 'Recovery', () => write(deployment.feed, feedAbi, 'setAnswer', [3_000n * 10n ** 8n]))
  onClick('toggle-stale', 'Primary staleness toggle', () => write(deployment.feed, feedAbi, 'setStale', [!current.stale]))
  onClick('toggle-unavailable', 'Primary availability toggle', () => write(deployment.feed, feedAbi, 'setUnavailable', [!current.unavailable]))
  onClick('day', 'Advance one day', () => advanceBy(86_400))
  onClick('three-days', 'Advance three days', () => advanceBy(259_200))
  onClick('checkpoint', 'Recovery checkpoint', () => reserveWrite('checkpointRecovery'))
}

async function init() {
  bindActions()
  try {
    const response = await fetch(`/local-deployment.json?t=${Date.now()}`, { cache: 'no-store' })
    if (!response.ok) throw new Error('Run make local-deploy to create ui/public/local-deployment.json')
    deployment = await response.json()
    if (deployment.chainId !== 31337) throw new Error('Deployment manifest is not for Anvil chain 31337')
    await refresh()
    if (window.ethereum) {
      const accounts = await window.ethereum.request({ method: 'eth_accounts' })
      if (accounts?.length && await window.ethereum.request({ method: 'eth_chainId' }) === '0x7a69') {
        account = accounts[0]
        walletClient = createWalletClient({ account, chain: foundry, transport: custom(window.ethereum) })
        setText('wallet-label', `Wallet ${short(account)}`)
        $('connect').textContent = short(account)
        await refresh()
      }
      window.ethereum.on?.('accountsChanged', accounts => {
        account = accounts?.[0]
        walletClient = account ? createWalletClient({ account, chain: foundry, transport: custom(window.ethereum) }) : null
        setText('wallet-label', account ? `Wallet ${short(account)}` : 'Wallet not connected')
        $('connect').textContent = account ? short(account) : 'Connect wallet'
        refresh()
      })
      window.ethereum.on?.('chainChanged', () => refresh())
    }
  } catch (error) {
    notice(error.message ?? String(error), true)
    setText('chain-status', 'Local deployment unavailable')
  }
  setInterval(refresh, 8_000)
}

init()
