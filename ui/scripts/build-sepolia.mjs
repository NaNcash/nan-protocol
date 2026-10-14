import { readFile, rm } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { getAddress } from 'viem'

const ui = resolve(import.meta.dirname, '..')

async function main() {
  const manifest = JSON.parse(await readFile(resolve(ui, 'public/sepolia-deployment.json'), 'utf8'))
  if (manifest.chainId !== 11155111) throw new Error('The published deployment must be Ethereum Sepolia (11155111)')
  if (!Number.isSafeInteger(manifest.deploymentBlock) || manifest.deploymentBlock < 0) throw new Error('Invalid deployment block')
  const fields = ['collateral', 'feed', 'fallbackOracle', 'oracle', 'reserve', 'authorizer', 'nan', 'inf']
  for (const field of fields) {
    const address = getAddress(manifest[field])
    if (address === '0x0000000000000000000000000000000000000000') throw new Error(`Invalid ${field} address`)
  }
  const allowed = new Set(['chainId', 'deploymentBlock', ...fields])
  for (const key of Object.keys(manifest)) {
    if (!allowed.has(key)) throw new Error(`Unexpected deployment field: ${key}`)
  }
  console.log(`Building Sepolia playground for reserve ${manifest.reserve}`)
  const result = spawnSync('npm', ['run', 'build'], {
    cwd: ui,
    env: { ...process.env, VITE_PLAYGROUND_NETWORK: 'sepolia' },
    stdio: 'inherit',
  })
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`Vite build failed with exit ${result.status}`)
  // Local development manifests can exist on a developer's machine; publish only Sepolia.
  await rm(resolve(ui, 'dist/local-deployment.json'), { force: true })
}

main().catch(error => {
  console.error(error.message)
  process.exitCode = 1
})
