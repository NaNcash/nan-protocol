import { spawn } from 'node:child_process'
import { resolve } from 'node:path'

if (!process.env.SEPOLIA_RPC_URL) throw new Error('Set SEPOLIA_RPC_URL in .env.sepolia')
const { PRIVATE_KEY, ETHERSCAN_API_KEY, ...env } = process.env
const child = spawn('npm', ['run', 'dev'], {
  cwd: resolve(import.meta.dirname, '../ui'),
  env: { ...env, VITE_PLAYGROUND_NETWORK: 'sepolia' },
  stdio: 'inherit',
})
child.on('error', error => { console.error(error.message); process.exitCode = 1 })
child.on('exit', code => { process.exitCode = code ?? 1 })
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal))
