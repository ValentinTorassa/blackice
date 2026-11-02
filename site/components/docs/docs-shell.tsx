import type { ReactNode } from 'react'

import { DocsPagination } from '@/components/docs/docs-pagination'
import { DocsSidebar } from '@/components/docs/docs-sidebar'
import { TableOfContents } from '@/components/docs/table-of-contents'
import { Footer } from '@/components/footer'

export function DocsShell({ children }: { children: ReactNode }) {
  return (
    <div data-wide-layout className="min-h-screen bg-background text-foreground">
      <main className="mx-auto grid w-full max-w-[1264px] gap-8 px-6 pt-6 min-[900px]:grid-cols-[200px_minmax(0,1fr)] min-[900px]:gap-12 min-[900px]:px-8 min-[900px]:pt-12 min-[1240px]:grid-cols-[200px_minmax(0,1fr)_180px]">
        <DocsSidebar />
        <article
          id="docs-content"
          className="min-w-0 max-w-[720px] [overflow-wrap:break-word] [&>*+*]:mt-5 [&_a:not(.heading-anchor)]:underline [&_a:not(.heading-anchor)]:decoration-border-strong [&_a:not(.heading-anchor)]:underline-offset-4 [&_a:not(.heading-anchor)]:transition-colors [&_a:not(.heading-anchor):hover]:decoration-foreground [&_h1]:text-[30px] [&_h1]:leading-[1.2] [&_h1]:font-semibold [&_h1]:tracking-[-0.03em] [&_h1+p]:!mt-2 [&_h1+p]:text-base [&_h1+p]:text-muted-foreground [&_h2]:!mt-12 [&_h2]:mb-4 [&_h2]:scroll-mt-6 [&_h2]:text-[19px] [&_h2]:leading-[1.35] [&_h2]:font-semibold [&_h2]:tracking-[-0.015em] [&_h2+*]:!mt-0 [&_li]:text-foreground/88 [&_li+li]:mt-2 [&_li::marker]:text-faint [&_p]:text-foreground/88 [&_strong]:font-semibold [&_ul]:list-disc [&_ul]:pl-5 [&_:not(pre)>code]:rounded-md [&_:not(pre)>code]:border [&_:not(pre)>code]:border-border [&_:not(pre)>code]:bg-card [&_:not(pre)>code]:px-[5px] [&_:not(pre)>code]:py-px"
        >
          {children}
          <DocsPagination />
        </article>
        <TableOfContents />
      </main>
      <Footer className="max-w-[1264px] min-[900px]:px-8" />
    </div>
  )
}
