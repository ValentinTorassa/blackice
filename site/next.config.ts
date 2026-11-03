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
  /* The Tailwind CSS is ~7.5 KiB, so ship it in a <style> tag with the HTML
     instead of a render-blocking <link>. Production builds only. */
  experimental: {
    inlineCss: true,
  },
  outputFileTracingIncludes: {
    '/docs.md': ['./app/(site)/(docs)/docs/**/*.mdx'],
    '/markdown/docs/\\[\\.\\.\\.slug\\]': ['./app/(site)/(docs)/docs/**/*.mdx'],
    '/llms-full.txt': ['./app/(site)/(docs)/docs/**/*.mdx'],
    '/install.sh': ['./lib/install.sh'],
  },
  rewrites: async () => [
    { source: '/docs/:slug(.+)\\.md', destination: '/markdown/docs/:slug' },
  ],
  redirects: async () => [
    { source: '/source', destination: 'https://github.com/ValentinTorassa/blackice', permanent: false },
  ],
}

export default withMDX(nextConfig)
