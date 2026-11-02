'use client'

import { usePathname } from 'next/navigation'

import { FastLink } from '@/components/fast-link'
import { getAdjacentDocs } from '@/lib/docs-nav'
import { site } from '@/lib/site-metadata'

const card =
  'flex flex-1 flex-col gap-1 rounded-xl border border-border px-4 py-3.5 !no-underline transition-colors hover:border-border-strong'

export function DocsPagination() {
  const pathname = usePathname()
  const { previous, next } = getAdjacentDocs(pathname)

  return (
    <>
      <p className="!mt-10">
        <a
          href={`${site.repo}/blob/main/site/app/(site)/(docs)${pathname}/page.mdx`}
          className="font-mono text-[13px] text-muted-foreground"
        >
          edit this page
        </a>
      </p>
      {previous || next ? (
        <nav className="!mt-14 flex gap-3 max-[420px]:flex-col" aria-label="Previous and next page">
          {previous ? (
            <FastLink href={previous.href} className={card}>
              <span className="font-mono text-xs text-faint">‹ previous</span>
              <span>{previous.title}</span>
            </FastLink>
          ) : (
            <span className="flex-1 max-[420px]:hidden" />
          )}
          {next ? (
            <FastLink href={next.href} className={`${card} items-end text-right`}>
              <span className="font-mono text-xs text-faint">next ›</span>
              <span>{next.title}</span>
            </FastLink>
          ) : (
            <span className="flex-1 max-[420px]:hidden" />
          )}
        </nav>
      ) : null}
    </>
  )
}
