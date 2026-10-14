import { defineConfig } from 'vite'

const proxy = {
  '/rpc': {
    target: process.env.VITE_PLAYGROUND_NETWORK === 'sepolia'
      ? process.env.SEPOLIA_RPC_URL
      : 'http://127.0.0.1:8545',
    changeOrigin: true,
    rewrite: path => path.replace(/^\/rpc/, ''),
  },
}

export default defineConfig({
  server: { proxy },
  preview: { proxy },
})
