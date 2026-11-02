'use client'

import { usePathname } from 'next/navigation'

import { FastLink } from '@/components/fast-link'
import { cn } from '@/lib/utils'

export function NavLink({ href, title }: { href: string; title: string }) {
  const active = usePathname() === href
  return (
    <FastLink
      href={href}
      aria-current={active ? 'page' : undefined}
      className={cn(
        'block py-1 text-sm transition-colors',
        active ? 'font-medium text-foreground' : 'text-muted-foreground hover:text-foreground',
      )}
    >
      {title}
    </FastLink>
  )
}
