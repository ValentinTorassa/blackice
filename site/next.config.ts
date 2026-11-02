import type { NextConfig } from 'next'
import createMDX from '@next/mdx'

const withMDX = createMDX({
  extension: /\.mdx?$/,
  options: {
    /* @sugar-high/remark highlights fenced code at build time, so pages ship
       plain spans and no highlighter JavaScript. Colors live in globals.css
       under the --sh-* variables. Plugins are named by string so Turbopack
       can load them. */
    remarkPlugins: ['remark-gfm', '@sugar-high/remark'],
    rehypePlugins: ['rehype-slug'],
  },
})

/* Instant Navigations (Cache Components): one reusable shell per route,
   prefetched once, so client navigations render instantly while keeping the
   server-driven model. */
const nextConfig: NextConfig = {
  pageExtensions: ['ts', 'tsx', 'mdx'],
  cacheComponents: true,
  partialPrefetching: true,
  poweredByHeader: false,
  outputFileTracingIncludes: {
    '/docs.md': ['./app/(site)/(docs)/docs/**/*.mdx'],
    '/docs/\\[\\.\\.\\.slug\\]': ['./app/(site)/(docs)/docs/**/*.mdx'],
    '/llms-full.txt': ['./app/(site)/(docs)/docs/**/*.mdx'],
  },
  redirects: async () => [
    { source: '/source', destination: 'https://github.com/ValentinTorassa/netshield', permanent: false },
  ],
}

export default withMDX(nextConfig)
