import { demo } from '@/lib/demo'
import { configExample, configIntro, details, hero, install, modes, status, steps } from '@/lib/landing-content'
import { release } from '@/lib/release'
import { canonicalSiteUrl, site } from '@/lib/site-metadata'

/* The homepage as markdown (/index.md), built from the same content as the
   page so the two can never disagree. */
export function createLandingMarkdown(): string {
  return [
    `# ${site.name}`,
    '',
    hero.headline,
    '',
    '## How it works',
    '',
    ...steps.map((step, index) => `${index + 1}. ${step}`),
    '',
    '## Modes',
    '',
    ...modes.map((mode) => `- \`${mode.name}\`: ${mode.body}`),
    '',
    '## Details',
    '',
    ...details.flatMap((paragraph) => [paragraph, '']),
    '## Configuration',
    '',
    configIntro,
    '',
    '```toml',
    configExample,
    '```',
    '',
    `## Install ${release.version}`,
    '',
    status,
    '',
    '```console',
    `$ ${install.curl}`,
    '```',
    '',
    install.script,
    '',
    '```console',
    ...install.brew.split('\n').map((command) => `$ ${command}`),
    '```',
    '',
    `${install.zip} GitHub release: ${release.url}. Install docs: ${canonicalSiteUrl}/docs/install.md.`,
    '',
    install.next,
    '',
    ...(demo.src ? ['## Demo', '', `[Demo video](${demo.src})`, ''] : []),
    '## More',
    '',
    `- [Documentation](${canonicalSiteUrl}/docs.md)`,
    `- [llms.txt](${canonicalSiteUrl}/llms.txt)`,
    `- [Source](${site.repo})`,
    '',
  ].join('\n')
}
