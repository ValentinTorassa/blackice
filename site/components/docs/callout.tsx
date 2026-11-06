import type { ReactNode } from 'react'

import { docsStatus } from '@/lib/release'
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

/* The introduction and the install page open with this: how far blackice has run. */
export function Status() {
  return (
    <Callout>
      <p>
        {docsStatus}
      </p>
    </Callout>
  )
}
