import { StrictMode } from 'react'
import ReactDOM from 'react-dom/client'
import { RouterProvider, createRouter } from '@tanstack/react-router'
import { QueryClientProvider } from '@tanstack/react-query'
import { client } from './api/client.gen'
import { queryClient } from './queryClient'
import './index.css'

// Import the generated route tree
import { routeTree } from './routeTree.gen'

// The one place outside a feature's hooks.ts that imports the generated
// client, and the exception is deliberate: this is client CONFIGURATION, not
// transport. The rule ("one file per feature imports ~/api") exists so codegen
// churn lands on one file per feature, and a singleton's configuration does
// not churn.
//
// codegen bakes in the baseUrl it introspected the schema from — a localhost
// address from whoever last ran `make migrate`. Overriding it here is what
// keeps that developer's port out of the production bundle. Empty means
// same-origin: the browser calls /api/... on whatever host served the page,
// which vite proxies in development and nginx serves directly in production.
client.setConfig({
  baseUrl: import.meta.env.VITE_API_BASE_URL ?? '',
  credentials: 'same-origin',
})

const router = createRouter({ routeTree })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

const rootElement = document.getElementById('root')!
if (!rootElement.innerHTML) {
  const root = ReactDOM.createRoot(rootElement)
  root.render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </StrictMode>,
  )
}
