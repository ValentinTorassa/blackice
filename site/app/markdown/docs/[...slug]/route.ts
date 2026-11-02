import { docsPages } from '@/lib/docs-nav'
import { getDocsMarkdown, markdownResponse } from '@/lib/docs-markdown'
import { createNotFoundMarkdown } from '@/lib/not-found-markdown'

/* Only /docs/*.md URLs rewrite here. Unsuffixed misses use Next's HTML 404. */
export function generateStaticParams() {
  return docsPages
    .filter((page) => page.href !== '/docs')
    .map((page) => ({ slug: page.href.replace('/docs/', '').split('/') }))
}

export async function GET(_request: Request, { params }: { params: Promise<{ slug: string[] }> }) {
  const { slug } = await params
  const markdown = await getDocsMarkdown(`/docs/${slug.join('/')}`)

  if (!markdown) {
    return markdownResponse(createNotFoundMarkdown(), { status: 404 })
  }

  return markdownResponse(markdown)
}
