import path from "path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig, loadEnv } from "vite"
import { tanstackRouter } from '@tanstack/router-plugin/vite'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  // Read the repo-root .env so one file configures both halves of the stack.
  // loadEnv's third argument is the prefix filter: '' loads everything, but
  // only VITE_-prefixed values are ever exposed to client code. Do NOT add
  // `define: { 'process.env': ... }` — that inlines the whole build
  // environment, secrets included, into a bundle every visitor downloads.
  const env = loadEnv(mode, path.resolve(__dirname, '..'), '')

  // In the container the backend is `backend:8000`; from a host shell it is
  // localhost on the published port.
  const proxyTarget =
    env.VITE_PROXY_TARGET || `http://localhost:${env.BACKEND_PORT || '8000'}`

  return {
    server: {
      watch: { usePolling: true },
      allowedHosts: ['localhost', '127.0.0.1', '0.0.0.0'],
      // The dev server proxies the API, so the browser talks to ONE origin
      // here exactly as it does behind nginx in production. That is what lets
      // the project carry no CORS configuration at all: nothing is ever
      // cross-origin, in either environment.
      proxy: {
        '/api': { target: proxyTarget, changeOrigin: true },
        '/admin': { target: proxyTarget, changeOrigin: true },
        '/static': { target: proxyTarget, changeOrigin: true },
      },
    },
    plugins: [
      tanstackRouter({
        target: 'react',
        autoCodeSplitting: true,
      }),
      tailwindcss(),
      react(),
    ],
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
  }
})
