import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { docsNav, docsPages, getDocsPage } from '@/lib/docs-nav'
import { figureText } from '@/lib/figures'
import { docsStatusMarkdown, release } from '@/lib/release'
import { canonicalSiteUrl, site } from '@/lib/site-metadata'

/* Markdown twins of the docs, generated from the MDX sources so the HTML and
   the markdown can never drift. Agents read these through /llms.txt. */

export function getMarkdownPath(href: string): string {
  return href === '/docs' ? '/docs.md' : `${href}.md`
}

function getSourcePath(href: string): string {
  return join(process.cwd(), 'app', '(site)', '(docs)', ...href.slice(1).split('/'), 'page.mdx')
}

/* The MDX sources use a small, fixed set of components. Each one becomes its
   text equivalent; anything else is left in place so a new component shows
   up in the output instead of silently disappearing. */
function convertComponents(source: string): string {
  return source
    .replace(/<Status\s*\/>/g, docsStatusMarkdown())
    .replace(/<(FigArchitecture|FigAsk)\s+n=\{(\d+)\}\s*\/>/g, (_m, name: string, n: string) =>
      `> **Figure ${n}.** ${figureText[name as keyof typeof figureText]}`,
    )
    .replace(/<Callout>\s*\n([\s\S]*?)\n<\/Callout>/g, (_m, body: string) =>
      body
        .trim()
        .split('\n')
        .map((line) => (line ? `> ${line}` : '>'))
        .join('\n'),
    )
}

/* Internal links point at the markdown twins, absolute so they resolve
   outside the site. Fenced code is skipped. */
function convertInternalLinks(source: string): string {
  return source.replace(
    /(^(`{3,})[^\n]*\n[\s\S]*?^\2[ \t]*$)|\]\((\/(?!\/)[^)\s#]*)(#[^)]+)?\)/gm,
    (match, fence: string | undefined, _f, path: string | undefined, hash = '') => {
      if (fence || !path) return match
      const target = getDocsPage(path) ? getMarkdownPath(path) : path
      return `](${canonicalSiteUrl}${target}${hash})`
    },
  )
}

function stripMetadata(source: string): string {
  return source
    .replace(/^import \{ getDocsMetadata \} from '@\/lib\/docs-metadata'\n+/m, '')
    .replace(/^export const metadata = getDocsMetadata\([^\n]*\)\n+/m, '')
}

export async function getDocsMarkdown(href: string): Promise<string | null> {
  'use cache'

  if (!getDocsPage(href)) return null
  const source = await readFile(getSourcePath(href), 'utf8')
  return `${convertInternalLinks(convertComponents(stripMetadata(source))).trim()}\n`
}

export function createLlmsText(): string {
  const sections = docsNav.map((section) =>
    [
      `## ${section.title}`,
      '',
      ...section.items.map(
        (page) => `- [${page.title}](${canonicalSiteUrl}${getMarkdownPath(page.href)}): ${page.description}`,
      ),
    ].join('\n'),
  )

  return [
    `# ${site.name}`,
    '',
    `> ${site.description}`,
    '',
    `blackice ${release.version} is early: it has run on one Mac, with macOS 27.0.1.`,
    '',
    `- [Home](${canonicalSiteUrl}/index.md): What blackice is, in one page.`,
    `- [All documentation](${canonicalSiteUrl}/llms-full.txt): Every page below in one file.`,
    `- [Source](${site.repo}): The repository, Apache-2.0.`,
    '',
    ...sections.flatMap((s) => [s, '']),
  ].join('\n')
}

export async function createLlmsFullText(): Promise<string> {
  const pages = await Promise.all(docsPages.map((page) => getDocsMarkdown(page.href)))
  return pages.filter(Boolean).join('\n---\n\n')
}

export function markdownResponse(
  body: string,
  { status = 200, contentType = 'text/markdown; charset=utf-8' } = {},
): Response {
  return new Response(body, {
    status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=0, s-maxage=3600, stale-while-revalidate=86400',
      'X-Content-Type-Options': 'nosniff',
    },
  })
}
