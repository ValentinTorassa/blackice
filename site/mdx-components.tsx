import type { MDXComponents } from 'mdx/types'
import type { ComponentPropsWithoutRef } from 'react'

import { Callout, Planned } from '@/components/docs/callout'
import { CodeBlock } from '@/components/docs/code-block'
import { FigArchitecture, FigAsk } from '@/components/docs/figures'
import { FastLink } from '@/components/fast-link'

type DocsHeadingProps = ComponentPropsWithoutRef<'h2'> & { as: 'h2' | 'h3' }

function DocsHeading({ as: Heading, id, children, ...props }: DocsHeadingProps) {
  return (
    <Heading id={id} {...props}>
      {id ? (
        <a
          href={`#${id}`}
          className="heading-anchor inline-flex items-baseline after:ml-2 after:font-normal after:text-faint after:opacity-0 after:transition-opacity after:content-['#'] hover:after:opacity-100 focus-visible:after:opacity-100"
        >
          {children}
        </a>
      ) : (
        children
      )}
    </Heading>
  )
}

/* Table styling lives on the elements it applies to rather than in the
   article's class list. */
function DocsTable(props: ComponentPropsWithoutRef<'table'>) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-left text-sm [&_tbody_tr:last-child_td]:border-b-0" {...props} />
    </div>
  )
}

function DocsTh(props: ComponentPropsWithoutRef<'th'>) {
  return (
    <th
      className="border-b border-border px-3 py-3 align-top font-mono text-xs font-normal text-faint first:pl-0 last:pr-0"
      {...props}
    />
  )
}

function DocsTd(props: ComponentPropsWithoutRef<'td'>) {
  return (
    <td
      className="border-b border-border px-3 py-3 align-top text-muted-foreground first:pl-0 last:pr-0 [overflow-wrap:break-word] [&_code]:whitespace-normal [&_code]:text-foreground"
      {...props}
    />
  )
}

export function useMDXComponents(components: MDXComponents): MDXComponents {
  return {
    a: ({ href = '', ...props }) => {
      if (href.startsWith('/')) return <FastLink href={href} {...props} />
      /* In-page anchors must not open a new tab. */
      if (href.startsWith('#')) return <a href={href} {...props} />
      return <a href={href} target="_blank" rel="noreferrer" {...props} />
    },
    h2: (props) => <DocsHeading as="h2" {...props} />,
    h3: (props) => <DocsHeading as="h3" {...props} />,
    pre: CodeBlock,
    table: DocsTable,
    th: DocsTh,
    td: DocsTd,
    Callout,
    Planned,
    FigArchitecture,
    FigAsk,
    ...components,
  }
}
