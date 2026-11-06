import { canonicalSiteUrl, site } from './site-metadata'

/* The current release, shared by the landing page, its markdown twin and
   the install docs' links. The zip and its checksum are attached to the
   GitHub release; macos/scripts/package.sh names them. */
const version = '1.0.2'

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
} as const

/* The note at the top of the introduction and the install page. */
export const docsStatus = `blackice ${version} has run on one Mac, with macOS 27.0.1; macOS 14 and 15 are not tested yet. A blackice.toml that works in 1.0 keeps working in every 1.x.`

export function docsStatusMarkdown(): string {
  return `> ${docsStatus}`
}
