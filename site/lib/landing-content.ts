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
  'An app, script, or command on your Mac opens a connection.',
  'The network extension allows it, denies it, or pauses it, depending on the mode and your rules.',
  'A paused connection becomes a request. You inspect it with `blackice pending` and answer with `blackice approve` or `blackice deny`.',
  'Optionally, a hook passes the request to an agent such as fx, which answers the same way.',
]

export type Mode = { name: string; body: string }

export const modes: Mode[] = [
  { name: 'accept-all', body: 'Allows every connection and logs it.' },
  { name: 'ask', body: 'Pauses any connection that no rule or approval covers yet.' },
  { name: 'block-all', body: 'Allows only what your rules allow.' },
]

export const details = [
  'An approval covers one app and one host, and it expires, for example after an hour. Rules you want to keep go in `blackice.toml`.',
  'Hooks receive metadata about the connection, not its payload, and do not run as root. You can run blackice by hand without fx.',
  "There is no window or menu bar icon. blackice is a network extension, a background service, and a CLI, written in Swift on Apple's Network Extension framework.",
  'It runs on macOS. The project is in planning, so there is nothing to install yet.',
]

export const configIntro = '`blackice.toml` holds the mode, your rules, and the optional hook.'

export const configExample = `mode = "ask"
timeout_seconds = 10

[[allow]]
app = "com.example.agent"
hosts = ["api.example.com"]

[[hook]]
on = "connection"
run = 'fx ask "Use the blackice skill to decide whether to approve the pending connection"'`
