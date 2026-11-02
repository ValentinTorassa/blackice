'use client'

import { useRef, useState, type ComponentPropsWithoutRef } from 'react'
import { Check, Copy } from 'lucide-react'

import { cn } from '@/lib/utils'

type CodeBlockProps = ComponentPropsWithoutRef<'pre'> & {
  /* Optional source override for generated examples. */
  code?: string
}

export function CodeBlock({ children, code, className, ...props }: CodeBlockProps) {
  const [copied, setCopied] = useState(false)
  const preRef = useRef<HTMLPreElement>(null)
  /* Copy on pointer-down for instant feedback, then suppress the click that
     follows on release. Keyboard activation has no prior pointer-down and
     falls through to copy. */
  const suppressRef = useRef(false)
  const timeoutRef = useRef<ReturnType<typeof setTimeout>>(undefined)

  const copy = async () => {
    try {
      await navigator.clipboard.writeText((code ?? preRef.current?.textContent ?? '').replace(/\n$/, ''))
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      /* Clipboard unavailable; keep the control ready to retry. */
    }
  }

  return (
    <div className="group relative">
      <pre
        {...props}
        ref={preRef}
        className={cn(
          'overflow-x-auto rounded-xl border border-border bg-card px-[18px] py-4 leading-[1.7] [&_code]:border-0 [&_code]:bg-transparent [&_code]:p-0',
          className,
        )}
      >
        {children}
      </pre>
      <button
        type="button"
        onPointerDown={() => {
          void copy()
          suppressRef.current = true
          clearTimeout(timeoutRef.current)
          timeoutRef.current = setTimeout(() => {
            suppressRef.current = false
          }, 500)
        }}
        onClick={() => {
          if (suppressRef.current) {
            clearTimeout(timeoutRef.current)
            suppressRef.current = false
            return
          }
          void copy()
        }}
        className="absolute top-2 right-2 flex size-8 cursor-pointer items-center justify-center rounded-md text-muted-foreground opacity-0 outline-none transition-[color,opacity] group-hover:opacity-100 hover:text-foreground focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-ring/50 [@media(hover:none)]:opacity-100"
        aria-label={copied ? 'Copied' : 'Copy code'}
      >
        {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
      </button>
    </div>
  )
}
