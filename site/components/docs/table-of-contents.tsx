'use client'

import { useEffect, useRef, useState } from 'react'
import { usePathname } from 'next/navigation'

import { collectVisibleHeadings, type TableOfContentsHeading } from './table-of-contents-headings'

function observeHeadings(headings: TableOfContentsHeading[], onActive: (id: string) => void): () => void {
  const observer = new IntersectionObserver(
    (entries) => {
      const visibleEntries = entries.filter((entry) => entry.isIntersecting)
      if (visibleEntries.length > 0) {
        const firstVisible = visibleEntries.reduce((prev, curr) =>
          prev.boundingClientRect.top < curr.boundingClientRect.top ? prev : curr,
        )
        onActive(firstVisible.target.id)
      }
    },
    { rootMargin: '-100px 0px -66% 0px', threshold: 0 },
  )

  headings.forEach(({ element }) => observer.observe(element))
  return () => observer.disconnect()
}

export function TableOfContents() {
  const pathname = usePathname()
  const [headings, setHeadings] = useState<TableOfContentsHeading[]>([])
  const [activeId, setActiveId] = useState('')
  const stopObserverRef = useRef<(() => void) | null>(null)

  useEffect(() => {
    stopObserverRef.current?.()
    stopObserverRef.current = null
    setHeadings([])
    setActiveId('')

    // Defer until the MDX headings are in the DOM.
    const raf = requestAnimationFrame(() => {
      const article = document.getElementById('docs-content')
      if (article) setHeadings(collectVisibleHeadings(article))
    })
    return () => cancelAnimationFrame(raf)
  }, [pathname])

  useEffect(() => {
    if (headings.length === 0) return
    const stop = observeHeadings(headings, setActiveId)
    stopObserverRef.current = stop
    return () => {
      stop()
      if (stopObserverRef.current === stop) stopObserverRef.current = null
    }
  }, [headings])

  return (
    <nav className="hidden min-[1240px]:block" aria-label="Table of contents">
      {headings.length > 1 ? (
        <div className="sticky top-8">
          <p className="mb-2 font-mono text-xs text-faint">on this page</p>
          <ul className="space-y-1.5 text-[13px]">
            {headings.map(({ id, text, level, element }) => (
              <li key={id}>
                <a
                  href={`#${id}`}
                  onClick={(event) => {
                    event.preventDefault()
                    element.scrollIntoView({ behavior: 'smooth', block: 'start' })
                    setActiveId(id)
                    window.history.pushState(null, '', `#${id}`)
                  }}
                  className={`block transition-colors ${level === 3 ? 'pl-3' : ''} ${
                    activeId === id ? 'text-foreground' : 'text-muted-foreground hover:text-foreground'
                  }`}
                >
                  {text}
                </a>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </nav>
  )
}
