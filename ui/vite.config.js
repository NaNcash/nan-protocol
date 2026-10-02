import { defineConfig } from 'vite'

const proxy = {
  '/rpc': {
    target: 'http://127.0.0.1:8545',
    changeOrigin: true,
    rewrite: path => path.replace(/^\/rpc/, ''),
  },
}

export default defineConfig({
  server: { proxy },
  preview: { proxy },
})
