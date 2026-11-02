import type { Metadata } from 'next'

import { getDocsPage } from '@/lib/docs-nav'
import { ogShared, twitterShared } from '@/lib/site-metadata'

export function getDocsMetadata(href: string): Metadata {
  const page = getDocsPage(href)
  if (!page) throw new Error(`Unknown documentation page: ${href}`)

  const { title, description } = page
  return {
    title,
    description,
    openGraph: { ...ogShared, type: 'website', url: href, title, description },
    twitter: { ...twitterShared, title, description },
  }
}
