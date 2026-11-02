import type { Metadata } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'

import './globals.css'

const geistSans = Geist({ subsets: ['latin'], variable: '--font-geist-sans', display: 'block' })
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono', display: 'block' })

export const metadata: Metadata = {
  title: 'Page not found',
  robots: { index: false },
}

/* Recovery links, not a dead end: an agent that lands here can find the
   documentation index without another guess. */
const recovery = [
  { href: '/', label: 'home' },
  { href: '/docs', label: 'docs' },
  { href: '/llms.txt', label: 'llms.txt' },
]

/* Unmatched URLs resolve outside the (site) route group, so this page has no
   root layout to inherit and supplies its own document. */
export default function NotFound() {
  return (
    <html lang="en" className="bg-background" suppressHydrationWarning>
      <body className={`${geistSans.variable} ${geistMono.variable} bg-background font-sans antialiased`}>
        <main className="mx-auto max-w-[768px] px-6 pt-32 text-center">
          <h1 className="text-[30px] font-semibold tracking-[-0.03em]">Page not found</h1>
          <p className="mt-3 text-muted-foreground">There is no page at this address.</p>
          <div className="mt-7 flex justify-center gap-6 font-mono text-[13px]">
            {recovery.map((item) => (
              <a key={item.href} href={item.href} className="text-muted-foreground transition-colors hover:text-foreground">
                {item.label}
              </a>
            ))}
          </div>
        </main>
      </body>
    </html>
  )
}
