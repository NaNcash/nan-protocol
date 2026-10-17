import './style.css'
import {
  createPublicClient, createWalletClient, custom, formatUnits, getAddress, http, isAddress,
  parseAbi, parseAbiItem, parseUnits,
} from 'viem'
import { foundry, sepolia } from 'viem/chains'

const $ = id => document.getElementById(id)
const WAD = 10n ** 18n
const errorAbi = parseAbi([
  'error ZeroAmount()',
  'error ZeroAddress()',
  'error InvalidConfiguration()',
  'error InvalidPrice()',
  'error UnsupportedCollateralDecimals()',
  'error DebtRatioTooHigh()',
  'error NoDebt()',
  'error NoJuniorCapital()',
  'error Slippage()',
  'error InsufficientInfPrecision()',
  'error UnsupportedTransferFee()',
  'error WithdrawalNotReady()',
  'error WithdrawalWindowClosed()',
  'error WithdrawalNotExpired()',
  'error WithdrawalAlreadySettled()',
  'error WithdrawalNotSettled()',
  'error NoWithdrawalRequest()',
  'error WithdrawalRequestExists()',
  'error NoWithdrawalCapacity()',
  'error RenounceDisabled()',
  'error UnsupportedFeedDecimals()',
  'error StalePrice()',
  'error InvalidRound()',
  'error FallbackUnavailable()',
  'error InvalidRate()',
  'error InvalidFaucetAmount()',
  'error FeedUnavailable()',
  'error OwnableUnauthorizedAccount(address account)',
  'error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)',
  'error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)',
])
const reserveAbi = [...errorAbi, ...parseAbi([
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
])]
const tokenAbi = [...errorAbi, ...parseAbi([
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
])]
const collateralAbi = [...errorAbi, ...parseAbi([
  'function faucet(uint256)',
  'function setStEthPerToken(uint256)',
  'function stEthPerToken() view returns (uint256)',
])]
const feedAbi = [...errorAbi, ...parseAbi([
  'function answer() view returns (int256)',
  'function stale() view returns (bool)',
  'function unavailable() view returns (bool)',
  'function setAnswer(int256)',
  'function setStale(bool)',
  'function setUnavailable(bool)',
])]
const fallbackAbi = [...errorAbi, ...parseAbi(['function priceValue() view returns (uint256)', 'function setPrice(uint256)'])]
const requestEvent = parseAbiItem('event WithdrawalRequested(address indexed account, uint256 indexed series, uint256 indexed epoch, uint256 infIn)')

const isSepolia = import.meta.env.VITE_PLAYGROUND_NETWORK === 'sepolia'
const defaultSepoliaRpc = 'https://ethereum-sepolia-rpc.publicnode.com'
const chain = isSepolia ? sepolia : foundry
const chainHex = `0x${chain.id.toString(16)}`
const rpcUrl = isSepolia
  ? import.meta.env.VITE_SEPOLIA_RPC_URL || (import.meta.env.DEV ? '/rpc' : defaultSepoliaRpc)
  : '/rpc'
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) })
const ownerAbi = parseAbi(['function owner() view returns (address)'])
let deployment
let tokens
let tokenDetails
let walletClient
let account
let busy = false
let refreshing = false
let current = {}
let controllers = {}
let walletChainId
let allowances = {}
const withdrawalLogCache = new Map()

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
  if (!window.ethereum) throw new Error('Install an injected wallet such as MetaMask and select a test wallet')
  return window.ethereum
}

async function verifyWalletRpc() {
  const injected = provider()
  try {
    if (await injected.request({ method: 'eth_chainId' }) !== chainHex) {
      throw new Error(`Switch your wallet to ${chain.name} (${chain.id})`)
    }
    const block = await injected.request({ method: 'eth_getBlockByNumber', params: ['latest', false] })
    if (!block?.number) throw new Error('Wallet RPC returned no latest block')
  } catch (error) {
    if (isSepolia) throw new Error(`Your wallet cannot reach Sepolia. Check its selected network and RPC connection. (${error.shortMessage ?? error.message})`)
    throw new Error(`Your wallet cannot reach the local Anvil RPC. In MetaMask → Settings → Networks, set the RPC URL for chain 31337 to http://127.0.0.1:8545, keep make local-chain running, then reconnect. The UI cannot replace the RPC URL of a network already saved in MetaMask. (${error.shortMessage ?? error.message ?? String(error)})`)
  }
}

async function ensureWallet() {
  const injected = provider()
  const desired = chainHex
  const actual = await injected.request({ method: 'eth_chainId' })
  walletChainId = actual
  if (actual !== desired) {
    try {
      await injected.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: desired }] })
    } catch (error) {
      if (error.code !== 4902) throw error
      await injected.request({ method: 'wallet_addEthereumChain', params: [{
        chainId: desired, chainName: chain.name,
        rpcUrls: isSepolia ? [defaultSepoliaRpc] : ['http://127.0.0.1:8545'],
        nativeCurrency: chain.nativeCurrency,
      }] })
    }
  }
  const accounts = await injected.request({ method: 'eth_requestAccounts' })
  if (!accounts?.length) throw new Error('No account selected in wallet')
  await verifyWalletRpc()
  walletChainId = chainHex
  account = accounts[0]
  walletClient = createWalletClient({ account, chain, transport: custom(injected) })
  setText('wallet-label', `Wallet ${short(account)}`)
  $('connect').textContent = short(account)
}

async function write(address, abi, functionName, args = []) {
  if (!deployment) throw new Error(`Deploy contracts first with make ${isSepolia ? 'sepolia' : 'local'}-deploy`)
  await ensureWallet()
  await verifyWalletRpc()
  if (await publicClient.getBalance({ address: account }) === 0n) {
    throw new Error(isSepolia ? 'This wallet needs native Sepolia ETH for gas. pgETH cannot pay transaction fees.' : 'This wallet has no local ETH for gas. Import a funded Anvil test account from the make local-chain terminal.')
  }
  notice(`Confirm ${functionName} in your wallet…`)
  const hash = await walletClient.writeContract({ address, abi, functionName, args, account, chain })
  notice(`${functionName} submitted · ${short(hash)} · waiting for confirmation…`)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted onchain`)
  return receipt
}
async function reserveWrite(functionName, args = []) { return write(deployment.reserve, reserveAbi, functionName, args) }
async function approveIfNeeded(token, value) {
  const allowance = await read(token, tokenAbi, 'allowance', [account, deployment.reserve])
  if (allowance < value) {
    await write(token, tokenAbi, 'approve', [deployment.reserve, value])
    return false
  }
  return true
}
async function execute(label, action, button) {
  if (busy) return
  busy = true
  const originalLabel = button?.textContent
  if (button) button.textContent = `${label}…`
  document.querySelectorAll('button').forEach(button => { if (button.id !== 'refresh') button.disabled = true })
  try {
    const result = await action()
    notice(typeof result === 'string' ? result : `${label} completed on ${chain.name}.`)
    await refresh()
  } catch (error) {
    notice(friendlyError(error), true)
  } finally {
    busy = false
    if (button && button.id !== 'connect') button.textContent = originalLabel
    $('connect').textContent = account ? short(account) : 'Connect wallet'
    updateButtonStates()
  }
}

async function localRpc(method, params = []) {
  if (isSepolia) throw new Error('Anvil controls are unavailable on Sepolia')
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
  button.dataset.actionLabel = text
  button.addEventListener('click', async () => {
    if (!account || walletChainId !== chainHex) {
      await execute('Wallet connection', ensureWallet, button)
      return
    }
    callback(button)
  })
  return button
}

async function showWithdrawals(now, blockNumber) {
  const container = $('withdrawals')
  container.replaceChildren()
  if (!account) { container.textContent = 'Connect a wallet to see its requests.'; return }
  const requestAccount = account
  const key = requestAccount.toLowerCase()
  const cache = withdrawalLogCache.get(key) ?? { nextBlock: BigInt(deployment.deploymentBlock), events: [] }
  withdrawalLogCache.set(key, cache)
  // Public Sepolia providers limit log ranges. Scan once in bounded chunks, then incrementally.
  while (cache.nextBlock <= blockNumber) {
    const toBlock = cache.nextBlock + 1_999n < blockNumber ? cache.nextBlock + 1_999n : blockNumber
    cache.events.push(...await publicClient.getLogs({
      address: deployment.reserve,
      event: requestEvent,
      args: { account: requestAccount },
      fromBlock: cache.nextBlock,
      toBlock,
    }))
    cache.nextBlock = toBlock + 1n
  }
  if (account !== requestAccount) return
  const events = cache.events
  let shown = 0
  for (const event of [...events].reverse()) {
    const { series, epoch } = event.args
    const [, requested] = await reserveRead('withdrawalRequests', [series, epoch, account])
    if (requested === 0n) continue
    shown++
    const [, totalRequested, filled, , settled, maturity] = await reserveRead('withdrawalEpochs', [series, epoch])
    const row = document.createElement('div')
    row.className = 'withdrawal'
    const heading = document.createElement('strong')
    heading.textContent = `Epoch ${epoch} · ${amount(requested)} INF`
    const detail = document.createElement('span')
    detail.textContent = settled ? 'Finalized — claim now'
      : filled > 0n ? `Partially filled: ${amount(filled)} / ${amount(totalRequested)} INF · closes ${date(BigInt(maturity) + 86_400n)}`
        : `Matures ${date(maturity)}`
    row.append(heading, detail)
    const actions = document.createElement('div')
    actions.className = 'inline-actions'
    const expiry = BigInt(maturity) + 86_400n
    if (settled) {
      actions.append(requestButton('Claim', button => execute('Claim', async () => reserveWrite('claimDefund', [series, epoch, 0n, account]), button)))
    } else if (now >= expiry) {
      actions.append(requestButton('Finalize cohort', button => execute('Finalize cohort', async () => reserveWrite('expireDefundEpoch', [series, epoch]), button)))
    } else if (now >= BigInt(maturity)) {
      actions.append(requestButton('Settle cohort', button => execute('Settle cohort', async () => reserveWrite('settleDefundEpoch', [series, epoch]), button)))
      if (!isSepolia && filled > 0n) actions.append(requestButton('Jump to expiry', () => execute('Advance chain', async () => advanceTo(expiry))))
    } else if (!isSepolia) {
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
    if (chainId !== chain.id) throw new Error(`RPC must be ${chain.name} chain ${chain.id}`)
    const bytecode = await publicClient.getCode({ address: deployment.reserve })
    if (!bytecode || bytecode === '0x') throw new Error(`Reserve bytecode missing on ${chain.name}; check the deployment manifest`)
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
    if (isSepolia) {
      controllers = Object.fromEntries(await Promise.all(['collateral', 'feed', 'fallbackOracle'].map(async key => [key, await read(deployment[key], ownerAbi, 'owner') ])))
    }
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
      allowances = Object.fromEntries(await Promise.all([['collateral', deployment.collateral], ['inf', tokens.inf]].map(async ([key, token]) => [key, await read(token, tokenAbi, 'allowance', [account, deployment.reserve]) ])))
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
    } else {
      allowances = {}
      for (const id of ['eth-balance', 'collateral-balance', 'nan-balance', 'inf-balance']) setText(id, '—')
    }
    await showWithdrawals(block.timestamp, block.number)
    updateButtonStates()
  } catch (error) {
    notice(friendlyError(error), true)
    setText('chain-status', `${chain.name} deployment unavailable`)
  } finally {
    refreshing = false
  }
}

function onForm(id, label, action) {
  const primary = $(id).querySelector('button[type="submit"]')
  if (id !== 'eth-form') primary.dataset.actionLabel = primary.textContent
  $(id).addEventListener('submit', event => {
    event.preventDefault()
    const form = event.currentTarget
    execute(label, async () => {
      if (id !== 'eth-form' && (!account || walletChainId !== chainHex)) {
        await ensureWallet()
        return 'Wallet ready. Choose the action to continue.'
      }
      return action(form)
    }, event.submitter)
  })
}
function onClick(id, label, action) {
  const needsWallet = !id.startsWith('copy-') && !['day', 'three-days'].includes(id)
  if (needsWallet) $(id).dataset.actionLabel = $(id).textContent
  $(id).addEventListener('click', event => execute(label, async () => {
    if (needsWallet && (!account || walletChainId !== chainHex)) {
      await ensureWallet()
      return 'Wallet ready. Choose the action to continue.'
    }
    return action()
  }, event.currentTarget))
}

function bindActions() {
  $('connect').addEventListener('click', event => execute('Wallet connection', ensureWallet, event.currentTarget))
  $('refresh').addEventListener('click', refresh)

  for (const key of ['collateral', 'nan', 'inf']) {
    onClick(`copy-${key}`, 'Address copy', async () => {
      const token = tokenDetails?.[key]
      if (!token) throw new Error('Wait for the token addresses to load')
      try {
        await navigator.clipboard.writeText(token.address)
      } catch {
        throw new Error('Clipboard access is unavailable; select and copy the address shown above')
      }
      return `${token.symbol} address copied: ${token.address}`
    })
    onClick(`watch-${key}`, 'Token import', async () => {
      const token = tokenDetails?.[key]
      if (!token) throw new Error('Wait for the token addresses to load')
      await ensureWallet()
      const accepted = await walletClient.watchAsset({
        type: 'ERC20',
        options: { address: token.address, symbol: token.symbol, decimals: token.decimals },
      })
      if (!accepted) throw new Error(`MetaMask did not accept the ${token.symbol} token suggestion`)
      return `${token.symbol} token suggestion sent to MetaMask; confirm it there if prompted.`
    })
  }

  onForm('eth-form', 'Local ETH top-up', async form => {
    if (isSepolia) throw new Error('Native Sepolia ETH must come from a testnet faucet')
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
    await ensureWallet()
    const collateralIn = formValue(form, 'amount')
    const quoted = await reserveRead('previewFund', [collateralIn])
    if (!await approveIfNeeded(deployment.collateral, collateralIn)) return 'Collateral approved. Click again to confirm the deposit.'
    await reserveWrite('fund', [collateralIn, quoted * 995n / 1000n, account])
  })
  onForm('mint-form', 'NaN mint', async form => {
    await ensureWallet()
    const collateralIn = formValue(form, 'amount')
    const price = await reserveRead('collateralPriceUsd')
    const fee = await reserveRead('mintFeeBps')
    const estimated = collateralIn * price / WAD * (10_000n - fee) / 10_000n
    if (!await approveIfNeeded(deployment.collateral, collateralIn)) return 'Collateral approved. Click again to confirm the deposit.'
    await reserveWrite('mint', [collateralIn, estimated * 995n / 1000n, account])
  })
  onForm('redeem-form', 'NaN redemption', async form => {
    await ensureWallet()
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
    await ensureWallet()
    const infIn = formValue(form, 'amount')
    if (!await approveIfNeeded(tokens.inf, infIn)) return 'INF approved. Click again to request withdrawal.'
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

function updateButtonStates() {
  document.querySelectorAll('button').forEach(button => { button.disabled = busy && button.id !== 'refresh' })
  updateActionLabels()
  const owned = owner => account && owner && account.toLowerCase() === owner.toLowerCase()
  const restrict = (selector, owner) => document.querySelectorAll(selector).forEach(button => {
    button.disabled = busy || (!!account && walletChainId === chainHex && !owned(owner))
    button.title = owned(owner) ? '' : 'Connect the controller wallet to use this action'
  })
  if (isSepolia) {
    restrict('#market-form button, #toggle-stale, #toggle-unavailable', controllers.feed)
    restrict('#rate-form button', controllers.collateral)
    restrict('#fallback-form button', controllers.fallbackOracle)
  }
  restrict('#delay-form button, #halving-form button', current.owner)
}

function configureNetworkUi() {
  if (!isSepolia) return
  document.title = 'NaN Sepolia Playground'
  document.querySelector('meta[name="description"]').content = 'NaN and INF on Sepolia with free playground collateral.'
  document.querySelector('.brand small').textContent = 'SEPOLIA PLAYGROUND'
  document.querySelector('.network').textContent = '● Sepolia · 11155111'
  document.querySelector('.hero > p:not(.eyebrow)').textContent = 'Get free pgETH, fund INF, mint NaN, and explore withdrawals on Ethereum Sepolia. pgETH is pretend collateral with no value; native Sepolia ETH is needed only for gas. Wallet activity and balances are public.'
  setText('chain-status', 'Checking Sepolia deployment…')
  notice('Connect a Sepolia test wallet to begin. Prices are simulated and scenario controls belong to the controller.')
  // Keep the existing local vocabulary in Anvil mode and name the test asset consistently here.
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  while (walker.nextNode()) {
    const node = walker.currentNode
    node.textContent = node.textContent.replaceAll('wstETH', 'pgETH').replaceAll('stETH', 'simulated ETH')
  }
  $('eth-form').hidden = true
  $('sepolia-gas').hidden = false
  document.querySelector('#faucet-form p').textContent = 'Anyone can mint up to 1,000 pgETH per transaction. Repeat whenever you need more; no native ETH deposit is required.'
  document.querySelector('#faucet-form button').textContent = 'Get free pgETH'
  document.querySelector('#token-address-collateral').previousElementSibling.firstChild.textContent = 'Playground ETH '
  document.querySelector('.token-grid').previousElementSibling.querySelector('h2').textContent = 'Sepolia tokens'
  document.querySelector('.token-grid').previousElementSibling.querySelector('p').textContent = 'These tokens belong to this Sepolia deployment. Add them to MetaMask on Sepolia.'
  $('scenario-description').textContent = 'Only the controller can change simulated prices, yield, and oracle failures. These settings affect every playground user.'
  $('time-description').textContent = 'Sepolia follows real time. Withdrawals mature after the displayed date; anyone can then settle the cohort.'
  $('day').hidden = true
  $('three-days').hidden = true
  document.querySelector('#day').closest('.panel').querySelector('h3').textContent = 'Chain time & recovery'
  document.querySelector('.fineprint').lastChild.textContent = ' · Prices are synthetic and controller-managed.'
  document.querySelector('footer').textContent = 'NaN Sepolia Playground · pgETH, NaN and INF are test tokens with no monetary value. Never send real funds.'
  updateButtonStates()
}

function friendlyError(error) {
  const cause = error.walk?.(entry => entry.data?.errorName)
  const name = cause?.data?.errorName
  const messages = {
    DebtRatioTooHigh: 'The debt ratio is too high. Fund INF or reduce the NaN mint amount.',
    NoJuniorCapital: 'Fund INF before minting NaN.',
    Slippage: 'The quote changed. Refresh and try again.',
    InsufficientInfPrecision: 'This amount is too small for a precise INF quote. Increase the amount.',
    NoWithdrawalCapacity: 'There is no safe withdrawal capacity at the current price and debt ratio.',
    WithdrawalNotReady: 'This withdrawal has not matured yet. Wait until the displayed date.',
    WithdrawalWindowClosed: 'The settlement window has closed. Finalize the cohort before claiming.',
    WithdrawalNotExpired: 'This cohort has not reached expiry yet.',
    WithdrawalNotSettled: 'Settle or finalize this cohort before claiming.',
    WithdrawalRequestExists: 'This wallet already has a request in the current cohort.',
    NoWithdrawalRequest: 'There is no open withdrawal request for this wallet.',
    StalePrice: 'The primary feed is stale. The controller must restore it to resume priced actions.',
    FeedUnavailable: 'The primary feed is unavailable. The controller must restore it.',
    InvalidPrice: 'The simulated primary price is invalid. The controller must correct it.',
    OwnableUnauthorizedAccount: 'Only this contract’s controller can change this setting.',
    InvalidFaucetAmount: 'Choose more than zero and at most 1,000 test collateral tokens.',
    InvalidRate: 'The simulated value multiplier must be greater than zero.',
    ERC20InsufficientBalance: 'This wallet has insufficient token balance for the amount entered.',
    ERC20InsufficientAllowance: 'Approve the required token amount before continuing.',
  }
  return messages[name] ?? error.shortMessage ?? error.message ?? String(error)
}

function updateActionLabels() {
  if (busy) return
  document.querySelectorAll('button[data-action-label]').forEach(button => {
    button.textContent = !account ? 'Connect wallet' : walletChainId !== chainHex ? `Switch to ${chain.name}` : button.dataset.actionLabel
  })
  if (!account || walletChainId !== chainHex) return
  for (const [id, token] of [['fund-form', 'collateral'], ['mint-form', 'collateral'], ['request-form', 'inf']]) {
    const button = $(id).querySelector('button[type="submit"]')
    const value = $(id).querySelector('input[name="amount"]').value
    try {
      if ((allowances[token] ?? 0n) < parseUnits(value, 18)) button.textContent = `Approve ${token === 'inf' ? 'INF' : isSepolia ? 'pgETH' : 'wstETH'}`
    } catch { /* Invalid input is handled by form validation. */ }
  }
}

async function init() {
  configureNetworkUi()
  bindActions()
  updateButtonStates()
  document.querySelectorAll('input[name="amount"]').forEach(input => input.addEventListener('input', updateActionLabels))
  try {
    const response = await fetch(`/${isSepolia ? 'sepolia' : 'local'}-deployment.json?t=${Date.now()}`, { cache: 'no-store' })
    if (!response.ok) throw new Error(`Run make ${isSepolia ? 'sepolia' : 'local'}-deploy to create the deployment manifest`)
    deployment = await response.json()
    if (deployment.chainId !== chain.id) throw new Error(`Deployment manifest must be for chain ${chain.id}`)
    for (const key of ['collateral', 'feed', 'fallbackOracle', 'oracle', 'reserve']) deployment[key] = getAddress(deployment[key])
    if (!Number.isSafeInteger(deployment.deploymentBlock) || deployment.deploymentBlock < 0) throw new Error('Invalid deployment block')
    await refresh()
    if (window.ethereum) {
      const accounts = await window.ethereum.request({ method: 'eth_accounts' })
      walletChainId = await window.ethereum.request({ method: 'eth_chainId' })
      if (accounts?.length) {
        account = accounts[0]
        walletClient = createWalletClient({ account, chain, transport: custom(window.ethereum) })
        setText('wallet-label', `Wallet ${short(account)}`)
        $('connect').textContent = short(account)
        await refresh()
      }
      window.ethereum.on?.('accountsChanged', accounts => {
        account = accounts?.[0]
        allowances = {}
        for (const id of ['eth-balance', 'collateral-balance', 'nan-balance', 'inf-balance']) setText(id, '—')
        updateButtonStates()
        walletClient = account ? createWalletClient({ account, chain, transport: custom(window.ethereum) }) : null
        setText('wallet-label', account ? `Wallet ${short(account)}` : 'Wallet not connected')
        $('connect').textContent = account ? short(account) : 'Connect wallet'
        refresh()
      })
      window.ethereum.on?.('chainChanged', chainId => {
        walletChainId = chainId
        updateButtonStates()
        refresh()
      })
    }
  } catch (error) {
    notice(error.message ?? String(error), true)
    setText('chain-status', `${chain.name} deployment unavailable`)
  }
  setInterval(refresh, 8_000)
}

init()
