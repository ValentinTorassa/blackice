import { canonicalSiteUrl } from '@/lib/site-metadata'

/* The 404 body served to agents. Mirrors the HTML page: state the miss, then
   point at the indexes that let a caller recover without guessing. */
export function createNotFoundMarkdown(): string {
  return [
    '# Page not found',
    '',
    'There is no page at this address.',
    '',
    '## Where to look next',
    '',
    `- [Documentation](${canonicalSiteUrl}/docs.md): The planned design.`,
    `- [llms.txt](${canonicalSiteUrl}/llms.txt): Every documentation page as markdown, with descriptions.`,
    `- [sitemap.xml](${canonicalSiteUrl}/sitemap.xml): Every indexable URL on this site.`,
    '',
  ].join('\n')
}
