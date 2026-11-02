import { site } from '@/lib/site-metadata'
import { cn } from '@/lib/utils'
import { FastLink } from './fast-link'

export function Footer({ className }: { className?: string }) {
  return (
    <footer className="mt-16 border-t border-border">
      <div
        className={cn(
          'mx-auto flex w-full max-w-[768px] flex-wrap justify-between gap-x-6 gap-y-2 px-6 pt-6 pb-10 font-mono text-[13px] text-muted-foreground',
          className,
        )}
      >
        <span>
          {site.name} · apache-2.0 · by{' '}
          {site.authors.map((author, index) => (
            <span key={author.name}>
              {index > 0 ? ' and ' : null}
              <a href={author.url} className="transition-colors hover:text-foreground">
                {author.name}
              </a>
            </span>
          ))}
        </span>
        <div className="flex gap-5">
          <FastLink href="/docs" className="transition-colors hover:text-foreground">
            docs
          </FastLink>
          <a href={site.repo} className="transition-colors hover:text-foreground" target="_blank" rel="noreferrer">
            github
          </a>
        </div>
      </div>
    </footer>
  )
}
