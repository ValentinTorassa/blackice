import type { Metadata } from 'next'

import { ogShared, site, twitterShared } from '@/lib/site-metadata'

const title = `${site.name} docs`
const description = `Documentation for ${site.name}, an application firewall for macOS: install, configuration and commands.`

/* metadataBase is inherited from the (site) root layout; openGraph/twitter
   are NOT (Next replaces them wholesale), hence the shared spreads. */
export const metadata: Metadata = {
  title,
  description,
  openGraph: { type: 'website', url: '/docs', title, description, ...ogShared },
  twitter: { title, description, ...twitterShared },
}

export default function DocsRootLayout({ children }: { children: React.ReactNode }) {
  return children
}
