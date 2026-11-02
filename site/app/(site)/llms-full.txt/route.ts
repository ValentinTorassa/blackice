import { createLlmsFullText, markdownResponse } from '@/lib/docs-markdown'

export async function GET() {
  return markdownResponse(await createLlmsFullText(), { contentType: 'text/plain; charset=utf-8' })
}
