import type { Metadata, Viewport } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import { GeistPixelSquare } from 'geist/font/pixel'

import { SiteHeader } from '@/components/landing/site-header'
import { ThemeProvider } from '@/components/theme-provider'
import { canonicalSiteUrl, ogShared, site, twitterShared } from '@/lib/site-metadata'
import { siteNavBootstrapScript } from '@/lib/site-nav'
import '../globals.css'

const geistSans = Geist({
  subsets: ['latin'],
  variable: '--font-geist-sans',
  display: 'swap',
})

const geistMono = Geist_Mono({
  subsets: ['latin'],
  variable: '--font-geist-mono',
  display: 'swap',
})

/* Shared root layout for the landing (/) and the docs (/docs). They share one
   <html> document so client navigations stay instant under Cache
   Components. */
export const metadata: Metadata = {
  metadataBase: new URL(canonicalSiteUrl),
  title: site.name,
  description: site.description,
  icons: { icon: '/logo.svg' },
  openGraph: { type: 'website', ...ogShared },
  twitter: { ...twitterShared },
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
}

export default function SiteRootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className="bg-background" suppressHydrationWarning>
      <head>
        {/* Raw inline script, not next/script: `beforeInteractive` only
            queues the code for the client runtime, well after first paint.
            A plain inline tag executes while the head is parsed. */}
        <script id="site-nav-active" dangerouslySetInnerHTML={{ __html: siteNavBootstrapScript }} />
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} ${GeistPixelSquare.variable} bg-background font-sans antialiased`}
      >
        <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
          {/* SiteHeader lives in the shared root so it persists across
              client navigations instead of remounting. */}
          <SiteHeader />
          {children}
        </ThemeProvider>
      </body>
    </html>
  )
}
