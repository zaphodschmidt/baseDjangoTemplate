import { QueryClient } from '@tanstack/react-query'

/**
 * The one place cache behaviour is configured.
 *
 * Per-hook `staleTime`/`gcTime`/`retry` overrides need a one-line comment
 * saying why. The reason is not tidiness: scattered overrides are how a repo
 * ends up with no answer to "how stale can this screen be?", and the answer
 * matters most for the screens nobody thought about.
 */
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Refetching on every window focus is the default and is usually wrong:
      // it multiplies request volume by how often people alt-tab.
      refetchOnWindowFocus: false,
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      // A 4xx will not become a 2xx by asking again; retrying it just delays
      // the error the user needs to see.
      retry: (failureCount, error) => {
        const status = (error as { status?: number })?.status
        if (status && status >= 400 && status < 500) return false
        return failureCount < 2
      },
    },
  },
})
