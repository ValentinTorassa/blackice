import { release } from './release'
import { site } from './site-metadata'

/* Landing copy, shared by the page and its markdown twin (/index.md). The
   vocabulary follows the project's own README and system map: an
   application firewall, requests you approve or deny from the CLI, and an
   agent as optional automation behind a hook. */

/* The project's one-line description, broken where it reads best on wide
   screens. */
const headlineLines = ['A headless application firewall', 'for macOS, operated through a CLI.']

export const hero = {
  headline: site.headline,
  headlineLines,
}

export const seeAlso = [
  { label: 'docs', href: '/docs' },
  { label: 'cli', href: '/docs/cli' },
  { label: 'github', href: site.repo },
] as const

export const steps = [
  'An app on your Mac opens a connection.',
  'blackice lets it through, drops it, or holds it, by the mode and your rules.',
  "A held connection waits for an answer: yours, with `blackice approve` or `blackice deny`, or an agent's, such as Claude Code or fx.",
  'With no answer in time, it is dropped.',
]

export type Mode = { name: string; body: string }

export const modes: Mode[] = [
  { name: 'accept-all', body: 'Allows every connection and logs it.' },
  { name: 'ask', body: 'Holds any connection that no rule or approval covers yet.' },
  { name: 'block-all', body: 'Allows only what your rules allow.' },
]

export const details = [
  'An approval covers one app and one host, and expires. Rules you want to keep go in `blackice.toml`.',
  'An agent sees where a connection goes, never what it sends, and does not run as root.',
  'There is no window: a menu bar icon shows the mode and what waits.',
]

export const status = `Early: ${release.version} has run on one Mac, with macOS 27.0.1. It needs macOS 14 or later on Apple silicon.`

export const install = {
  curl: release.curl,
  script: 'The script checks the release and copies Blackice.app to `/Applications`. Or with Homebrew:',
  brew: release.brew,
  /* The page links "GitHub release" and "install docs"; the markdown twin
     appends the URLs. */
  zip: `Or download ${release.zip} from the GitHub release and check it as the install docs describe.`,
  next: 'Then run `blackice start`. It asks a few questions and opens System Settings so you can allow the extension.',
}

export const configIntro = '`blackice.toml` holds the mode and your rules. The first `blackice start` writes it.'

export const configExample = `mode = "ask"

[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]`
