'use client'

import { usePathname } from 'next/navigation'
import { useEffect, useState } from 'react'

import { FastLink } from '@/components/fast-link'
import { seeAlso } from '@/lib/landing-content'
import { site } from '@/lib/site-metadata'
import { activeSiteNavLabel, preHydrationActiveClass } from '@/lib/site-nav'

export function SiteHeader() {
  /* The header lives in the shared root layout and persists across site
     navigations. A shared Cache Components shell can prerender with a
     different pathname than the browser, so the server and first client
     render stay route-neutral; the bootstrap script in the root layout marks
     the active link before paint, and the live pathname takes over after
     hydration. */
  const pathname = usePathname()
  const [mounted, setMounted] = useState(false)
  const active = activeSiteNavLabel(mounted ? pathname : '')

  useEffect(() => {
    setMounted(true)
  }, [])

  useEffect(() => {
    if (mounted) delete document.documentElement.dataset.siteNavActive
  }, [mounted])

  return (
    <header className="mx-auto flex h-16 w-full max-w-[768px] items-center justify-between gap-6 px-6 [body:has([data-wide-layout])_&]:max-w-[1264px] [body:has([data-wide-layout])_&]:min-[900px]:px-8">
      <FastLink href="/" className="font-semibold tracking-[-0.01em]" aria-label={`${site.name} home`}>
        {site.name}
      </FastLink>
      <nav className="flex items-center gap-4 font-mono text-[13px] text-muted-foreground min-[521px]:gap-6" aria-label="Main">
        {seeAlso.map((link) => {
          const cls = `transition-colors ${
            link.label === active
              ? 'text-foreground'
              : `hover:text-foreground ${preHydrationActiveClass[link.label] ?? ''}`
          }`
          return link.href.startsWith('/') ? (
            <FastLink
              key={link.label}
              href={link.href}
              aria-current={link.label === active ? 'page' : undefined}
              className={cls}
            >
              {link.label}
            </FastLink>
          ) : (
            /* Off-site links open in a new tab so the visit survives the click. */
            <a key={link.label} href={link.href} className={cls} target="_blank" rel="noreferrer">
              {link.label}
            </a>
          )
        })}
      </nav>
    </header>
  )
}
