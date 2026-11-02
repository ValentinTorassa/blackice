import { markdownResponse } from '@/lib/docs-markdown'
import { createLandingMarkdown } from '@/lib/landing-markdown'

export function GET() {
  return markdownResponse(createLandingMarkdown())
}
