import { getDocsMarkdown, markdownResponse } from '@/lib/docs-markdown'

export async function GET() {
  const markdown = await getDocsMarkdown('/docs')
  if (!markdown) return markdownResponse('# Documentation not found\n', { status: 404 })

  return markdownResponse(markdown)
}
