import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, readFile } from 'node:fs/promises'
import net from 'node:net'
import { resolve } from 'node:path'

const repo = resolve(import.meta.dirname, '..')
const ui = resolve(repo, 'ui')
const statePath = resolve(repo, '.anvil/state.json')
const manifestPath = resolve(ui, 'public/local-deployment.json')
const rpcUrl = 'http://127.0.0.1:8545'
const children = new Set()
let stopping = false

function portInUse(port) {
  return new Promise(resolveResult => {
    const socket = net.connect({ host: '127.0.0.1', port })
    socket.setTimeout(500)
    socket.once('connect', () => { socket.destroy(); resolveResult(true) })
    socket.once('timeout', () => { socket.destroy(); resolveResult(false) })
    socket.once('error', () => resolveResult(false))
  })
}

async function rpc(method, params = []) {
  const response = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(1_000),
  })
  if (!response.ok) throw new Error(`RPC returned HTTP ${response.status}`)
  const payload = await response.json()
  if (payload.error) throw new Error(payload.error.message)
  return payload.result
}

function run(command, args, cwd = repo) {
  const child = spawn(command, args, { cwd, stdio: 'inherit' })
  children.add(child)
  child.once('close', () => children.delete(child))
  return child
}

function waitForExit(child) {
  return new Promise((resolveResult, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolveResult({ code: child.exitCode, signal: child.signalCode })
      return
    }
    child.once('error', reject)
    child.once('close', (code, signal) => resolveResult({ code, signal }))
  })
}

async function runToCompletion(command, args, cwd = repo) {
  const result = await waitForExit(run(command, args, cwd))
  if (result.code !== 0) throw new Error(`${command} exited with ${result.code ?? result.signal}`)
}

async function waitForAnvil(child) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error('Anvil stopped before its RPC was ready')
    try {
      const chainId = Number(BigInt(await rpc('eth_chainId')))
      if (chainId !== 31337) throw new Error(`Expected chain 31337, got ${chainId}`)
      return
    } catch (error) {
      if (error.message.startsWith('Expected chain')) throw error
      await new Promise(resolveResult => setTimeout(resolveResult, 100))
    }
  }
  throw new Error('Anvil RPC did not become ready on port 8545')
}

async function verifyRestoredDeployment() {
  if (!existsSync(manifestPath)) {
    throw new Error('Saved Anvil state exists but the deployment manifest is missing; refusing to redeploy over saved state')
  }
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
  if (manifest.chainId !== 31337) throw new Error('Saved deployment manifest has the wrong chain ID')
  for (const name of ['collateral', 'feed', 'fallbackOracle', 'oracle', 'reserve']) {
    const address = manifest[name]
    if (!/^0x[0-9a-fA-F]{40}$/.test(address ?? '') || await rpc('eth_getCode', [address, 'latest']) === '0x') {
      throw new Error(`Saved deployment is missing ${name}; refusing to redeploy over saved state`)
    }
  }
  console.log('Restored the saved Anvil chain and existing NaN deployment.')
}

async function stop() {
  if (stopping) return
  stopping = true
  if (children.size > 0) console.log('\nStopping local playground; Anvil will save its state...')
  const exits = [...children].map(child => {
    const exited = waitForExit(child)
    child.kill('SIGINT')
    return exited
  })
  await Promise.allSettled(exits)
}

process.on('SIGINT', () => { void stop() })
process.on('SIGTERM', () => { void stop() })

async function main() {
  if (await portInUse(8545)) throw new Error('Port 8545 is already in use; stop the other RPC before running make local')
  const existingUi = await portInUse(5173)
  if (existingUi) {
    const response = await fetch('http://127.0.0.1:5173/', { signal: AbortSignal.timeout(1_000) })
    if (!response.ok || !(await response.text()).includes('<title>NaN Local Lab</title>')) {
      throw new Error('Port 5173 is occupied by another service; stop it before running make local')
    }
    console.log('Using the NaN UI already running on port 5173; this command will leave that UI running.')
  }

  if (!existsSync(resolve(ui, 'node_modules/.bin/vite'))) {
    console.log('Installing UI dependencies...')
    await runToCompletion('npm', ['ci', '--prefix', 'ui'])
  }

  await mkdir(resolve(repo, '.anvil'), { recursive: true })
  const hadState = existsSync(statePath)
  const anvil = run('anvil', [
    '--host', '127.0.0.1', '--port', '8545', '--chain-id', '31337',
    '--state', statePath, '--state-interval', '15',
  ])
  await waitForAnvil(anvil)

  if (hadState) {
    await verifyRestoredDeployment()
  } else {
    console.log('Fresh chain: deploying NaN contracts...')
    await runToCompletion(process.execPath, ['scripts/local-deploy.mjs'])
  }

  const vite = existingUi ? null : run(resolve(ui, 'node_modules/.bin/vite'), ['--host', '127.0.0.1', '--port', '5173', '--strictPort'], ui)
  console.log('Local playground ready. Forward both ports 5173 and 8545 if using a remote browser.')
  console.log('Press Ctrl-C to stop; state is saved in .anvil/state.json.')
  const firstExit = await Promise.race([waitForExit(anvil), ...(vite ? [waitForExit(vite)] : [])])
  if (!stopping) {
    process.exitCode = 1
    console.error(`A local service stopped unexpectedly (${firstExit.code ?? firstExit.signal}).`)
  }
  await stop()
}

main().catch(async error => {
  process.exitCode = 1
  console.error(error.message)
  await stop()
})
