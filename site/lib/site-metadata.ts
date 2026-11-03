import type { Metadata } from 'next'

/* The public identity, stable across production, preview, and local
   deployments. The site has no domain yet: set NEXT_PUBLIC_SITE_URL when it
   does. On Vercel the production URL is used meanwhile. */
const vercelProductionHost = process.env.VERCEL_PROJECT_PRODUCTION_URL
export const canonicalSiteUrl =
  process.env.NEXT_PUBLIC_SITE_URL ??
  (vercelProductionHost ? `https://${vercelProductionHost}` : 'http://127.0.0.1:4319')

export const site = {
  name: 'blackice',
  headline: 'A headless application firewall for macOS, operated through a CLI.',
  description:
    'blackice is a headless application firewall for macOS, operated through a CLI. New connections can wait for you, or an optional hook such as fx, to approve or deny them.',
  repo: 'https://github.com/ValentinTorassa/blackice',
  authors: [
    { name: 'Valen Torassa', url: 'https://valentorassa.com' },
    { name: 'Esteban Suárez', url: 'https://github.com/suarezesteban' },
  ],
} as const

/* Next.js replaces (not deep-merges) a child layout's openGraph/twitter
   objects wholesale, so any layout that re-declares them must carry the
   shared fields itself: spread these in. */
export const ogShared = {
  siteName: site.name,
} satisfies Metadata['openGraph']

export const twitterShared = {
  card: 'summary',
} satisfies Metadata['twitter']
