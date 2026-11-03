import type { ReactNode } from 'react'

import { docsStatus, release } from '@/lib/release'
import { cn } from '@/lib/utils'

export function Callout({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        'rounded-xl border border-border bg-card px-4 py-3.5 text-sm text-muted-foreground [&_p]:text-muted-foreground [&_strong]:font-medium [&_strong]:text-foreground',
        className,
      )}
    >
      {children}
    </div>
  )
}

/* Every docs page opens with this: how far blackice has run. */
export function Status() {
  return (
    <Callout>
      <p>
        <strong>{docsStatus.lead}</strong> {docsStatus.before}{' '}
        <a
          href={release.evidence}
          target="_blank"
          rel="noreferrer"
          className="text-foreground underline decoration-border-strong underline-offset-4 hover:decoration-foreground"
        >
          {docsStatus.link}
        </a>{' '}
        {docsStatus.after}
      </p>
    </Callout>
  )
}
