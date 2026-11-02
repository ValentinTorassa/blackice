import type { Metadata, Viewport } from 'next'

import { Footer } from '@/components/footer'
import { ogShared, site, twitterShared } from '@/lib/site-metadata'

const title = `${site.name}: ${site.headline}`

/* metadataBase is inherited from the (site) root layout; openGraph/twitter
   are NOT (Next replaces them wholesale), hence the shared spreads. */
export const metadata: Metadata = {
  title,
  description: site.description,
  alternates: { canonical: '/' },
  openGraph: { type: 'website', url: '/', title, description: site.description, ...ogShared },
  twitter: { title, description: site.description, ...twitterShared },
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#ffffff' },
    { media: '(prefers-color-scheme: dark)', color: '#000000' },
  ],
}

export default function LandingLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <Footer />
    </>
  )
}
