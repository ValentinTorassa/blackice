import type { MetadataRoute } from 'next'

import { docsPages } from '@/lib/docs-nav'
import { canonicalSiteUrl } from '@/lib/site-metadata'

const publicPagePaths = ['/', ...docsPages.map((page) => page.href)]

export default function sitemap(): MetadataRoute.Sitemap {
  return publicPagePaths.map((path) => ({ url: new URL(path, canonicalSiteUrl).toString() }))
}
