'use client'

import Link from 'next/link'
import { type ComponentProps, useRef } from 'react'

/* FastLink is a superset of next/link that starts the navigation on
   mousedown instead of waiting for the click, shaving the press → release
   latency off every internal nav.

   It does not reimplement Link. It calls el.click() on pointer-down, which
   fires next/link's own onClick, so prefetch, modifier-key bail, scroll and
   replace all behave as usual. The redundant native click that follows on
   mouseup is suppressed.

   Touch is not fast-pathed: at touchstart a tap is indistinguishable from the
   start of a scroll. Keyboard activation fires a real click with no prior
   pointer-down, so the suppression flag is never armed. */

type FastLinkProps = Omit<ComponentProps<typeof Link>, 'onMouseDown'> & {
  onMouseDown?: React.MouseEventHandler<HTMLAnchorElement>
}

/* Mirrors next/link's isModifiedEvent so modified clicks fall through to the
   browser's native behavior (new tab, download, etc.). */
function shouldBail(event: {
  metaKey: boolean
  ctrlKey: boolean
  shiftKey: boolean
  altKey: boolean
  currentTarget: HTMLElement
}): boolean {
  const target = event.currentTarget.getAttribute('target')
  return (
    (target != null && target !== '_self') ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey ||
    event.currentTarget.hasAttribute('download')
  )
}

export function FastLink({ onClick, onMouseDown, children, ...props }: FastLinkProps) {
  /* A 500ms timeout self-heals the drag-away case: press, drag off the link,
     release elsewhere, and no click fires to clear the flag. */
  const suppressRef = useRef(false)
  const timeoutRef = useRef<ReturnType<typeof setTimeout>>(undefined)

  const navigate = (el: HTMLAnchorElement) => {
    el.click()
    suppressRef.current = true
    clearTimeout(timeoutRef.current)
    timeoutRef.current = setTimeout(() => {
      suppressRef.current = false
    }, 500)
  }

  return (
    <Link
      {...props}
      onMouseDown={(event) => {
        if (shouldBail(event) || event.button !== 0) return
        navigate(event.currentTarget)
        /* Pointer navigation should not leave a focused link behind. */
        event.preventDefault()
        onMouseDown?.(event)
      }}
      onClick={(event) => {
        if (suppressRef.current) {
          clearTimeout(timeoutRef.current)
          suppressRef.current = false
          event.preventDefault()
          return
        }
        onClick?.(event)
      }}
    >
      {children}
    </Link>
  )
}
