import { createLlmsText, markdownResponse } from '@/lib/docs-markdown'

export function GET() {
  return markdownResponse(createLlmsText(), { contentType: 'text/plain; charset=utf-8' })
}
