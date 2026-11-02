import type { Metadata } from 'next'

import { DocsShell } from '@/components/docs/docs-shell'
import { site } from '@/lib/site-metadata'

export const metadata: Metadata = {
  title: {
    default: `${site.name} docs`,
    template: `%s | ${site.name} docs`,
  },
}

export default function DocsLayout({ children }: { children: React.ReactNode }) {
  return <DocsShell>{children}</DocsShell>
}
