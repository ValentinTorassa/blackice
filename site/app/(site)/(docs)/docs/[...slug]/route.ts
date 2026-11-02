import { docsPages } from '@/lib/docs-nav'
import { getDocsMarkdown, markdownResponse } from '@/lib/docs-markdown'
import { createNotFoundMarkdown } from '@/lib/not-found-markdown'

/* The markdown twins are known at build time, so prerender them instead of
   reading MDX per request. Unlisted slugs still fall through to the 404. */
export function generateStaticParams() {
  return docsPages
    .filter((page) => page.href !== '/docs')
    .map((page) => {
      const segments = page.href.replace('/docs/', '').split('/')
      segments[segments.length - 1] = `${segments.at(-1)}.md`
      return { slug: segments }
    })
}

export async function GET(_request: Request, { params }: { params: Promise<{ slug: string[] }> }) {
  const { slug } = await params
  const lastSegment = slug.at(-1)

  if (!lastSegment?.endsWith('.md')) {
    return markdownResponse(createNotFoundMarkdown(), { status: 404 })
  }

  const markdownSlug = [...slug]
  markdownSlug[markdownSlug.length - 1] = lastSegment.slice(0, -3)
  const markdown = await getDocsMarkdown(`/docs/${markdownSlug.join('/')}`)

  if (!markdown) {
    return markdownResponse(createNotFoundMarkdown(), { status: 404 })
  }

  return markdownResponse(markdown)
}
