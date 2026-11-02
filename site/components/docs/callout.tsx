import type { ReactNode } from 'react'

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

/* Every design page opens with this: netshield is in planning. */
export function Planned() {
  return (
    <Callout>
      <p>
        <strong>Planned.</strong> Nothing on this page is implemented yet.
      </p>
    </Callout>
  )
}
