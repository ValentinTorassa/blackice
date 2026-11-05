import { canonicalSiteUrl, site } from './site-metadata'

/* The current release, shared by the landing page, its markdown twin and
   the install docs' links. The zip and its checksum are attached to the
   GitHub release; macos/scripts/package.sh names them. */
const version = '0.4.4'

export const release = {
  version,
  tag: `v${version}`,
  url: `${site.repo}/releases/tag/v${version}`,
  zip: `Blackice-${version}.zip`,
  checksum: `Blackice-${version}.zip.sha256`,
  /* app/install.sh serves lib/install.sh, which pins this same version. */
  curl: `curl -fsSL ${canonicalSiteUrl}/install.sh | sh`,
  /* Two commands: Homebrew loads a cask from a tap other than its own only
     after `brew trust`. */
  brew: 'brew trust --cask valentintorassa/tap/blackice\nbrew install --cask valentintorassa/tap/blackice',
  evidence: `${site.repo}/tree/main/evidence`,
} as const

/* The note at the top of each docs page, as text with the evidence link
   kept apart so the page and the markdown twin can each render it. */
export const docsStatus = {
  lead: 'Early.',
  before: `blackice ${version} has run on one Mac, with macOS 27.0.1. Something counts as working only when a run in the repository's`,
  link: 'evidence',
  after: 'folder records it, and the configuration format can still change.',
} as const

export function docsStatusMarkdown(): string {
  return `> **${docsStatus.lead}** ${docsStatus.before} [${docsStatus.link}](${release.evidence}) ${docsStatus.after}`
}
